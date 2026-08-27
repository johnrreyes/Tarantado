import Foundation
import DAPDB
import DAPDevice

/// What went wrong applying a `SyncPlan`, for the failures that stop the
/// whole sync (as opposed to a single file failing — see `SyncReport.failures`).
public enum SyncEngineError: Error, LocalizedError, Equatable {
    /// This device's firmware checks a signature over the database that
    /// this library cannot compute yet. Writing an unsigned database to a
    /// device that expects one risks the device rejecting (or worse,
    /// mishandling) its own music library — refusing outright is the only
    /// safe option until that signature algorithm is implemented.
    case databaseSignatureRequired(DatabaseSignatureRequirement)
    /// The device's `iTunesDB` has no playlist marked as the master
    /// playlist, so newly added tracks would have nowhere to be listed.
    case noMasterPlaylist
    /// The plan doesn't fit even before starting.
    case insufficientSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .databaseSignatureRequired(let requirement):
            return requirement.refusalExplanation +
                " Refusing to write an unsigned database rather than risk corrupting the device's library."
        case .noMasterPlaylist:
            return "The device's iTunesDB has no master playlist; can't add tracks to it."
        case .insufficientSpace(let required, let available):
            return "This sync needs \(required) bytes but only \(available) are available on the device."
        }
    }
}

/// Progress reported while `SyncEngine.apply` runs.
public struct SyncProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case backingUp
        case parsingDatabase
        case copying(fileIndex: Int, totalFiles: Int)
        case removing(fileIndex: Int, totalFiles: Int)
        case writingDatabase
    }

    public var phase: Phase
    public var currentFile: String?
    public var bytesCopied: Int64
    public var bytesTotal: Int64

    public init(phase: Phase, currentFile: String? = nil, bytesCopied: Int64 = 0, bytesTotal: Int64 = 0) {
        self.phase = phase
        self.currentFile = currentFile
        self.bytesCopied = bytesCopied
        self.bytesTotal = bytesTotal
    }
}

/// The outcome of applying a `SyncPlan`: per-file successes and failures, so
/// that one bad file never hides whether the rest of the sync worked.
public struct SyncReport: Sendable, Equatable {
    public struct AddResult: Sendable, Equatable {
        public let sourceFileURL: URL
        public let iPodPath: String
        public let uniqueID: UInt32
        public let bytesCopied: Int64
    }

    public struct RemoveResult: Sendable, Equatable {
        public let uniqueID: UInt32
    }

    public struct Failure: Sendable, Equatable {
        public let sourceFileURL: URL?
        public let message: String
    }

    public var added: [AddResult] = []
    public var removed: [RemoveResult] = []
    public var failures: [Failure] = []
    public var backup: BackupManager.Backup?
    /// `true` if the sync was cancelled partway through. When `true`, the
    /// on-device database was never rewritten (any files copied during this
    /// pass have already been deleted again), so the device is exactly as
    /// it was before the sync started — except for any removals that had
    /// already deleted their audio file before cancellation was noticed;
    /// see the doc on `SyncEngine.apply`.
    public var cancelled = false

    public init(
        added: [AddResult] = [],
        removed: [RemoveResult] = [],
        failures: [Failure] = [],
        backup: BackupManager.Backup? = nil,
        cancelled: Bool = false
    ) {
        self.added = added
        self.removed = removed
        self.failures = failures
        self.backup = backup
        self.cancelled = cancelled
    }
}

/// A file copy that failed, saying which half of the copy failed and where.
struct CopyError: Error, LocalizedError {
    enum Step: String {
        case creatingDestination = "create the file on the DAP"
        case openingSource = "read the source file"
        case openingDestination = "write to the file on the DAP"
        case transferring = "copy the file's contents"
    }

    let step: Step
    let path: String
    let underlying: Error?

    var errorDescription: String? {
        var message = "Couldn't \(step.rawValue): \(path)"
        if let underlying {
            message += " — \(underlying.localizedDescription)"
        }
        return message
    }
}

/// Applies a computed `SyncPlan` to a real device: backs it up, copies new
/// audio files, mutates the database in memory, deletes removed files, and
/// finally writes the database back atomically.
public enum SyncEngine {
    private static let copyChunkSize = 1 << 20 // 1 MiB

    /// Applies `plan` to `volume`. See the type doc above for the ordering
    /// guarantees. A single file failing to copy (or a single removal
    /// failing) is recorded in the returned report's `failures` and does
    /// not stop the rest of the sync; the on-device database is only
    /// written once, at the very end, so a sync that's cancelled or that
    /// fails outright before that point never leaves a half-written
    /// database behind.
    ///
    /// Cancellation (`Task.cancel()`) is checked between every file. If
    /// cancellation is noticed during the *add* phase, every file already
    /// copied during this call is deleted again before returning, so no
    /// orphaned (unreferenced) audio files are left behind — and the report's
    /// `added` is emptied to match, since a cancelled sync never writes the
    /// database and so adds nothing. The *remove*
    /// phase cannot offer the same guarantee — deleting a device's audio
    /// file is inherently irreversible, and `BackupManager` only backs up
    /// the database files, not music content — so if cancellation lands
    /// mid-removal, files already deleted during this pass stay deleted
    /// even though (because the database is never written after a
    /// cancellation) the old, on-disk database still references them. This
    /// is a known, documented gap; see the module's report.
    public static func apply(
        plan: SyncPlan,
        to volume: DAPVolume,
        progress: (@Sendable (SyncProgress) -> Void)? = nil
    ) async throws -> SyncReport {
        guard volume.model.requiresDatabaseSignature == .none else {
            throw SyncEngineError.databaseSignatureRequired(volume.model.requiresDatabaseSignature)
        }

        guard !plan.isEmpty else {
            return SyncReport()
        }

        let initialCapacity = try volume.capacity()
        guard plan.fits(in: initialCapacity) else {
            throw SyncEngineError.insufficientSpace(required: plan.bytesRequired, available: initialCapacity.availableBytes)
        }

        var report = SyncReport()

        // MARK: Backup

        progress?(SyncProgress(phase: .backingUp))
        let backupManager = BackupManager(volume: volume)
        do {
            report.backup = try backupManager.createBackup()
        } catch BackupManager.BackupError.nothingToBackUp {
            // Nothing on the device yet to protect; proceed without a backup.
        }

        if Task.isCancelled {
            report.cancelled = true
            return report
        }

        // MARK: Parse database

        progress?(SyncProgress(phase: .parsingDatabase))
        let existingData = try Data(contentsOf: volume.iTunesDBURL)
        var db = try ITunesDatabase(parsing: existingData)

        // A database mirrors its master playlist across two mhsd sections
        // under one persistent ID, and only the copy in the section the
        // firmware actually reads matters. Taking the first master in
        // document order happens to pick the right one on the verified mini
        // 2G, but that is an accident of how iTunes ordered the sections —
        // so prefer the model's verified section, and fall back to document
        // order only for models whose section we haven't established.
        let masterInVerifiedSection = volume.model.playlistSectionType.flatMap { sectionType in
            db.playlistSections
                .first { $0.sectionType == sectionType }?
                .playlists
                .first { $0.isMaster }
        }
        guard let masterPlaylist = masterInVerifiedSection ?? db.playlists.first(where: \.isMaster) else {
            throw SyncEngineError.noMasterPlaylist
        }
        let masterPlaylistID = masterPlaylist.id
        var nextPlaylistPosition = UInt32(masterPlaylist.trackIDsInOrder.count)

        var usedUniqueIDs = Set(db.tracks.map(\.uniqueID))
        func allocateUniqueID() -> UInt32 {
            var candidate = (usedUniqueIDs.max() ?? 0) &+ 1
            while usedUniqueIDs.contains(candidate) { candidate &+= 1 }
            usedUniqueIDs.insert(candidate)
            return candidate
        }

        // MARK: Parse (or create) ArtworkDB
        //
        // Only for models `DeviceModel.supportsArtwork` — every other device
        // is left exactly as before this feature existed, including devices
        // this library already refuses to write to for unrelated reasons
        // (the `requiresDatabaseSignature` guard above already stops those).
        //
        // A missing ArtworkDB is treated as "no artwork synced yet" and
        // started fresh. One that exists but fails to parse is different: an
        // ArtworkDB in a shape this library doesn't understand is not
        // something to guess about by silently replacing it, so artwork is
        // skipped for this sync rather than risking real content that just
        // couldn't be read. Consistent with `DeviceModel`'s "refuse rather
        // than guess" posture elsewhere in this module.
        var artworkEnabled = volume.model.supportsArtwork
        var artworkDB: ArtworkDatabase?
        if artworkEnabled {
            if FileManager.default.fileExists(atPath: volume.artworkDBURL.path) {
                if let existingArtData = try? Data(contentsOf: volume.artworkDBURL),
                   let parsed = try? ArtworkDatabase(parsing: existingArtData) {
                    artworkDB = parsed
                } else {
                    artworkEnabled = false
                }
            } else {
                artworkDB = ArtworkDatabase.makeEmpty(
                    formats: ArtworkEncoder.ipod5GFormats.map {
                        (formatID: $0.formatID, imageSizeBytes: UInt32($0.width * $0.height * 2))
                    }
                )
            }
        }

        var usedImageIDs = Set(artworkDB?.images.map(\.imageID) ?? [])
        var nextImageID = artworkDB.map { UInt32(MHFD($0.root)?.nextID ?? 100) } ?? 100
        func allocateImageID() -> UInt32 {
            var candidate = max(nextImageID, (usedImageIDs.max() ?? 0) &+ 1)
            while usedImageIDs.contains(candidate) { candidate &+= 1 }
            usedImageIDs.insert(candidate)
            nextImageID = candidate &+ 1
            return candidate
        }

        let artworkFileWriter = artworkEnabled ? ArtworkFileWriter(volume: volume) : nil
        // Keyed on the raw source image bytes, not a hash of them — these
        // are small (tens of KB) and `Data` is already `Hashable`, so this
        // avoids pulling in a hashing dependency for no real benefit. Lets
        // an album's dozen identically-tagged tracks encode and write their
        // shared cover art to `.ithmb` exactly once per sync, rather than
        // once per track — mirroring iOpenPod's `artwork_writer.py` dedup,
        // though libgpod's own writer doesn't bother (it re-embeds per
        // track). Every track still gets its own `mhii`; only the pixel
        // bytes and their `.ithmb` location are shared.
        var artworkLocationCache: [Data: [ArtworkThumbnailLocation]] = [:]

        // MARK: Add

        var copiedFileURLs: [URL] = []
        var remainingSpace = initialCapacity.availableBytes

        // Undoes this pass's copies. Also clears `report.added`: those files
        // have just been deleted and the database is never written after a
        // cancellation, so nothing was added in any sense a caller cares
        // about. Leaving them listed makes a cancelled sync report "Added:
        // 10" for ten tracks that are not on the device — which is what the
        // Sync screen would then show the user.
        func rollbackCopiedFiles() {
            for url in copiedFileURLs {
                try? FileManager.default.removeItem(at: url)
            }
            copiedFileURLs.removeAll()
            report.added.removeAll()
        }

        let allocator = try MusicFolderAllocator(volume: volume)

        for (index, item) in plan.toAdd.enumerated() {
            if Task.isCancelled {
                rollbackCopiedFiles()
                report.cancelled = true
                return report
            }

            guard item.source.fileSize <= remainingSpace else {
                report.failures.append(SyncReport.Failure(
                    sourceFileURL: item.source.fileURL,
                    message: "Not enough free space remaining on the device for this file."
                ))
                continue
            }

            progress?(SyncProgress(
                phase: .copying(fileIndex: index, totalFiles: plan.toAdd.count),
                currentFile: item.source.fileURL.lastPathComponent,
                bytesCopied: 0,
                bytesTotal: item.source.fileSize
            ))

            do {
                let ext = item.source.fileURL.pathExtension.isEmpty ? "dat" : item.source.fileURL.pathExtension
                let allocated = try await allocator.allocate(fileExtension: ext)

                let bytesCopied = try streamCopy(from: item.source.fileURL, to: allocated.url) { copied in
                    progress?(SyncProgress(
                        phase: .copying(fileIndex: index, totalFiles: plan.toAdd.count),
                        currentFile: item.source.fileURL.lastPathComponent,
                        bytesCopied: copied,
                        bytesTotal: item.source.fileSize
                    ))
                }
                copiedFileURLs.append(allocated.url)
                remainingSpace -= bytesCopied

                let uniqueID = allocateUniqueID()
                var fields = MHIT.Fields(uniqueID: uniqueID)
                fields.filetypeMarker = item.format.filetypeMarker
                fields.size = UInt32(clamping: bytesCopied)
                fields.length = UInt32(clamping: item.source.durationMS)
                fields.trackNumber = UInt32(clamping: item.source.trackNumber ?? 0)
                fields.totalTracks = UInt32(clamping: item.source.totalTracks ?? 0)
                fields.year = UInt32(clamping: item.source.year ?? 0)
                fields.bitrate = UInt32(clamping: item.source.bitrateKbps ?? 0)
                fields.sampleRate = UInt32(clamping: item.source.sampleRateHz ?? 0)
                fields.discNumber = UInt32(clamping: item.source.discNumber ?? 0)
                fields.totalDiscs = UInt32(clamping: item.source.totalDiscs ?? 0)
                fields.dateAdded = Date()
                fields.dbid = UInt64.random(in: 1...UInt64.max)
                fields.mediaType = 1 // ITDB_MEDIATYPE_AUDIO
                fields.compilation = item.source.isCompilation

                if artworkEnabled, let artworkFileWriter {
                    if let artworkData = item.source.artworkData {
                        do {
                            let locations = try await locateOrEncodeArtwork(
                                artworkData, writer: artworkFileWriter, cache: &artworkLocationCache
                            )
                            let thumbnails = locations.map { location in
                                MHNI.make(
                                    formatID: location.formatID,
                                    ithmbOffset: location.offset,
                                    imageSize: UInt32(location.pixelByteCount),
                                    imageWidth: location.imageWidth,
                                    imageHeight: location.imageHeight,
                                    horizontalPadding: location.horizontalPadding,
                                    verticalPadding: location.verticalPadding,
                                    ithmbFileName: ":" + location.filename
                                )
                            }
                            var imageFields = MHII.Fields(imageID: allocateImageID(), songID: fields.dbid)
                            imageFields.origImageSize = UInt32(clamping: artworkData.count)
                            try artworkDB?.addImage(MHII.make(imageFields, thumbnails: thumbnails))

                            fields.hasArtwork = 1
                            fields.artworkCount = 1
                            fields.artworkSize = UInt32(clamping: artworkData.count)
                        } catch {
                            // Soft failure, matching `SourceTrack.artworkData`'s
                            // own contract: a track whose art can't be decoded
                            // or written still syncs, just without art.
                            fields.hasArtwork = 2
                        }
                    } else {
                        fields.hasArtwork = 2
                    }
                }

                var strings: [MHOD.Kind: String] = [.location: allocated.iPodPath, .filetype: item.format.filetypeString]
                strings[.title] = item.source.title
                if let artist = item.source.artist { strings[.artist] = artist }
                if let albumArtist = item.source.albumArtist { strings[.albumArtist] = albumArtist }
                if let album = item.source.album { strings[.album] = album }
                if let genre = item.source.genre { strings[.genre] = genre }
                if let composer = item.source.composer { strings[.composer] = composer }

                let trackChunk = MHIT.make(fields, strings: strings)
                try db.addTrack(trackChunk)
                try db.addPlaylistEntry(MHIP.make(trackID: uniqueID, position: nextPlaylistPosition), toPlaylistID: masterPlaylistID)
                nextPlaylistPosition += 1

                report.added.append(SyncReport.AddResult(
                    sourceFileURL: item.source.fileURL,
                    iPodPath: allocated.iPodPath,
                    uniqueID: uniqueID,
                    bytesCopied: bytesCopied
                ))
            } catch is CancellationError {
                rollbackCopiedFiles()
                report.cancelled = true
                return report
            } catch {
                // `String(describing:)` on an NSError dumps the whole
                // domain/code/userInfo blob, which is what a user ends up
                // reading. Prefer the error's own written description.
                report.failures.append(SyncReport.Failure(sourceFileURL: item.source.fileURL, message: Self.describe(error)))
            }
        }

        // MARK: Remove

        for (index, item) in plan.toRemove.enumerated() {
            if Task.isCancelled {
                rollbackCopiedFiles()
                report.cancelled = true
                return report
            }

            progress?(SyncProgress(
                phase: .removing(fileIndex: index, totalFiles: plan.toRemove.count),
                currentFile: item.deviceTrack.title ?? item.deviceTrack.location
            ))

            do {
                if let location = item.deviceTrack.location, !location.isEmpty {
                    let fileURL = DAPPath.url(forDAPPath: location, relativeTo: volume)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        try FileManager.default.removeItem(at: fileURL)
                    }
                }
                try db.removeTrack(uniqueID: item.deviceTrack.uniqueID)
                artworkDB?.removeImage(forTrackDBID: item.deviceTrack.dbid)
                report.removed.append(SyncReport.RemoveResult(uniqueID: item.deviceTrack.uniqueID))
            } catch {
                report.failures.append(SyncReport.Failure(
                    sourceFileURL: nil,
                    message: "Failed to remove track \(item.deviceTrack.uniqueID): \(Self.describe(error))"
                ))
            }
        }

        if Task.isCancelled {
            rollbackCopiedFiles()
            report.cancelled = true
            return report
        }

        // MARK: Write database

        progress?(SyncProgress(phase: .writingDatabase))
        let serialized = db.serialized()
        try BackupManager.atomicWrite(serialized, to: volume.iTunesDBURL, forceFallback: false)

        if artworkEnabled, var finalArtworkDB = artworkDB {
            finalArtworkDB.setNextImageID(nextImageID)
            try BackupManager.atomicWrite(finalArtworkDB.serialized(), to: volume.artworkDBURL, forceFallback: false)
        }
        // Known gap, same shape as the one documented on `apply` above for
        // mid-removal cancellation: a cancelled or failed sync can leave
        // `.ithmb` bytes appended for tracks whose `mhit`/`mhii` never made
        // it into a written database (both `db` and `artworkDB` only reach
        // disk here, at the very end). Those bytes are inert and
        // unreferenced by anything — unlike an orphaned whole audio file,
        // there's no user-visible clutter, just a few extra KB of dead space
        // in a `.ithmb` file — so this is left undone rather than adding
        // rollback machinery for appended byte ranges.

        // Per-write stripping is not sufficient on its own. Each write site
        // strips the sidecar it just caused, but macOS stamps
        // `com.apple.provenance` asynchronously — under App Sandbox it can
        // land *after* the strip, re-materializing a sidecar for a file that
        // was already cleaned. Observed on a real device: a sandboxed sync
        // left a `._` beside every track it copied, where the same sync from
        // the CLI left none.
        //
        // So finish with one sweep over the control directory, which is also
        // the only way to catch sidecars for files a failed copy left behind.
        // Scoped to iPod_Control deliberately: the volume root holds the
        // user's own unrelated files, which are none of our business.
        AppleDoubleCleanup.stripRecursively(in: volume.controlDirectory)

        return report
    }

    // MARK: - Artwork

    /// Where one thumbnail format's pixels ended up, resolved either by
    /// encoding fresh bytes or by reusing an already-written location for
    /// artwork this sync has already seen (see `artworkLocationCache` in
    /// `apply`).
    private struct ArtworkThumbnailLocation {
        let formatID: UInt32
        let filename: String
        let offset: UInt32
        let pixelByteCount: Int
        let imageWidth: UInt16
        let imageHeight: UInt16
        let horizontalPadding: Int16
        let verticalPadding: Int16
    }

    /// Encodes `artworkData` into every device thumbnail format and appends
    /// each to its `.ithmb` file, or — if this exact image's bytes are
    /// already in `cache` from earlier in this same sync — returns the
    /// locations already written, encoding and writing nothing.
    private static func locateOrEncodeArtwork(
        _ artworkData: Data,
        writer: ArtworkFileWriter,
        cache: inout [Data: [ArtworkThumbnailLocation]]
    ) async throws -> [ArtworkThumbnailLocation] {
        if let cached = cache[artworkData] {
            return cached
        }

        let thumbnails = try ArtworkEncoder.encode(artworkData)
        var locations: [ArtworkThumbnailLocation] = []
        locations.reserveCapacity(thumbnails.count)
        for thumbnail in thumbnails {
            let written = try await writer.append(formatID: thumbnail.formatID, pixelData: thumbnail.pixelData)
            locations.append(ArtworkThumbnailLocation(
                formatID: thumbnail.formatID,
                filename: written.filename,
                offset: written.offset,
                pixelByteCount: thumbnail.pixelData.count,
                imageWidth: thumbnail.imageWidth,
                imageHeight: thumbnail.imageHeight,
                horizontalPadding: thumbnail.horizontalPadding,
                verticalPadding: thumbnail.verticalPadding
            ))
        }
        cache[artworkData] = locations
        return locations
    }

    /// A human-readable description of an error, preferring one the error
    /// wrote for itself.
    public static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    // MARK: - Stream copy

    /// Copies `source` to `destinationURL` in fixed-size chunks (never
    /// loading the whole file into memory), reporting cumulative bytes
    /// copied after each chunk. Checks `Task.isCancelled` between chunks;
    /// on cancellation (or any other failure), the partially-written
    /// destination file is removed before rethrowing, so callers never see
    /// a half-copied file left on disk.
    private static func streamCopy(
        from source: URL,
        to destinationURL: URL,
        chunkSize: Int = copyChunkSize,
        onProgress: (Int64) -> Void
    ) throws -> Int64 {
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CopyError(step: .creatingDestination, path: destinationURL.path, underlying: nil)
        }

        // Each handle is opened separately so a failure names which side
        // failed. A sandboxed host can lose access to the *source* (its
        // security scope having ended with the scan) just as easily as to
        // the destination, and the two need very different fixes — a copy
        // error that only says "permission denied" sends you looking at the
        // wrong one.
        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: source)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw CopyError(step: .openingSource, path: source.path, underlying: error)
        }

        let writer: FileHandle
        do {
            writer = try FileHandle(forWritingTo: destinationURL)
        } catch {
            try? reader.close()
            try? fileManager.removeItem(at: destinationURL)
            throw CopyError(step: .openingDestination, path: destinationURL.path, underlying: error)
        }

        func cleanUp() {
            try? reader.close()
            try? writer.close()
            try? fileManager.removeItem(at: destinationURL)
        }

        var total: Int64 = 0
        do {
            while true {
                if Task.isCancelled {
                    cleanUp()
                    throw CancellationError()
                }
                guard let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                try writer.write(contentsOf: chunk)
                total += Int64(chunk.count)
                onProgress(total)
            }
        } catch is CancellationError {
            cleanUp()
            throw CancellationError()
        } catch {
            cleanUp()
            throw CopyError(step: .transferring, path: source.path, underlying: error)
        }

        try? reader.close()
        try? writer.close()

        stripAppleDoubleArtifacts(at: destinationURL)
        return total
    }

    /// Removes extended attributes from a freshly-copied file, and deletes any
    /// AppleDouble sidecar the filesystem materialized for it.
    ///
    /// These devices are FAT32, which has no native xattr support, so macOS stores
    /// any extended attribute in a companion `._NAME` file. Recent macOS releases
    /// tag written files with `com.apple.provenance` automatically — we never
    /// ask for it — which is enough to litter a 4 KB `._FUOR.mp3` next to every
    /// single track. iTunes leaves no such files, and they waste space and clutter
    /// the device's directories, so strip them at the source.
    static func stripAppleDoubleArtifacts(at url: URL) {
        removeAllExtendedAttributes(at: url)

        let sidecar = url
            .deletingLastPathComponent()
            .appendingPathComponent("._" + url.lastPathComponent)
        try? FileManager.default.removeItem(at: sidecar)
    }

    private static func removeAllExtendedAttributes(at url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }

            let size = listxattr(path, nil, 0, 0)
            guard size > 0 else { return }

            var names = [CChar](repeating: 0, count: size)
            guard listxattr(path, &names, size, 0) == size else { return }

            // The buffer is a run of NUL-terminated names.
            var start = 0
            for index in 0..<size where names[index] == 0 {
                if index > start {
                    let name = String(cString: Array(names[start..<index]) + [0])
                    _ = removexattr(path, name, 0)
                }
                start = index + 1
            }
        }
    }
}
