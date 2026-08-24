import Foundation
import Testing
import DAPDB
import DAPDevice
@testable import DAPSync

@Suite struct SyncEngineTests {
    // Master playlist's persistent ID in the golden fixture (also used by
    // DAPDBTests.PlaylistMutationTests — confirmed via manual parsing of
    // the fixture bytes).
    private static let masterPlaylistID: UInt64 = 0x652463f2791cfe3d

    private func makeVolume(root: URL) throws -> DAPVolume {
        try DAPVolume.validate(at: root)
    }

    private func makeSourceWAV(in dir: URL, name: String, durationSeconds: Double = 0.2) throws -> (url: URL, size: Int64) {
        let url = dir.appendingPathComponent(name)
        try SyntheticAudio.makeWAV(at: url, durationSeconds: durationSeconds)
        let size = try Int64((FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        return (url, size)
    }

    private func wavSourceTrack(url: URL, size: Int64, title: String, artist: String, album: String? = nil, durationMS: Int = 200, extra: (inout SourceTrack) -> Void = { _ in }) -> SourceTrack {
        var track = SourceTrack(
            fileURL: url,
            fileSize: size,
            title: title,
            artist: artist,
            album: album,
            durationMS: durationMS,
            compatibility: .passThrough(SourceAudioFormat(kind: .wav, filetypeMarker: 0x2056_4157, filetypeString: "WAV audio file"))
        )
        extra(&track)
        return track
    }

    // MARK: - Progress

    /// The per-file progress bar can only animate if the engine reports
    /// partial byte counts as a copy runs. A file larger than the 1 MiB copy
    /// chunk must therefore produce at least one reading strictly between
    /// empty and complete — if the only readings were 0 and "done", every bar
    /// would jump straight to full no matter how the UI consumed them.
    @Test func copyReportsIntermediateByteCountsForAMultiChunkFile() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolume(root: root)

        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        // Comfortably several copy chunks' worth of audio.
        let (url, size) = try makeSourceWAV(in: sourceDir, name: "long.wav", durationSeconds: 30)
        #expect(size > 3 * 1024 * 1024)

        let plan = SyncPlan.compute(
            deviceTracks: [],
            sourceTracks: [wavSourceTrack(url: url, size: size, title: "Long", artist: "Art", durationMS: 30_000)]
        )

        let collector = ProgressCollector()
        let report = try await SyncEngine.apply(plan: plan, to: volume) { collector.record($0) }
        #expect(report.failures.isEmpty)

        let copyReadings = collector.readings.filter {
            if case .copying = $0.phase { return true } else { return false }
        }
        let partials = copyReadings.filter { $0.bytesCopied > 0 && $0.bytesCopied < $0.bytesTotal }
        #expect(!partials.isEmpty)

        // And the readings for the file must never go backwards.
        let counts = copyReadings.map(\.bytesCopied)
        #expect(counts == counts.sorted())
    }

    /// Cancels a task that may not have been assigned yet. The progress
    /// callback can fire before `Task {}` even returns its handle to the
    /// caller, so a request that arrives early is remembered and applied the
    /// moment the handle shows up.
    private final class Canceller: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<SyncReport, Error>?
        private var cancelRequestedEarly = false

        func adopt(_ task: Task<SyncReport, Error>) {
            lock.lock()
            self.task = task
            let shouldCancel = cancelRequestedEarly
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func requestCancel() {
            lock.lock()
            let existing = task
            if existing == nil { cancelRequestedEarly = true }
            lock.unlock()
            existing?.cancel()
        }
    }

    /// Collects progress callbacks, which arrive on whatever thread the copy
    /// loop happens to be running on.
    private final class ProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SyncProgress] = []

        func record(_ progress: SyncProgress) {
            lock.lock()
            storage.append(progress)
            lock.unlock()
        }

        var readings: [SyncProgress] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - Refusal

    @Test func refusesDeviceRequiringDatabaseSignature() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }

        let baseVolume = try makeVolume(root: root)
        let riskyModel = DeviceModel(
            displayName: "iPod classic (6th generation, 80GB)",
            generation: "classic 6G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .hash58,
            supportsArtwork: true,
            musicFolderCount: 50
        )
        let riskyVolume = DAPVolume(rootURL: baseVolume.rootURL, sysInfo: baseVolume.sysInfo, model: riskyModel)

        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let (url, size) = try makeSourceWAV(in: sourceDir, name: "a.wav")
        let plan = SyncPlan.compute(
            deviceTracks: [],
            sourceTracks: [wavSourceTrack(url: url, size: size, title: "A", artist: "Art")]
        )

        await #expect(throws: SyncEngineError.self) {
            _ = try await SyncEngine.apply(plan: plan, to: riskyVolume)
        }

        // And crucially: nothing was written.
        #expect(!FileManager.default.fileExists(atPath: riskyVolume.iTunesDirectory.appendingPathComponent(".iopenpod-backups").path))
    }

    // MARK: - No-op

    @Test func emptyPlanIsANoOpAndTouchesNothing() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolume(root: root)

        let report = try await SyncEngine.apply(plan: SyncPlan(), to: volume)
        #expect(report.added.isEmpty)
        #expect(report.removed.isEmpty)
        #expect(report.backup == nil)
        #expect(!FileManager.default.fileExists(atPath: BackupManager(volume: volume).backupsDirectory.path))
    }

    // MARK: - Add, then reparse

    @Test func addingTracksCopiesFilesAndTheDatabaseReparsesWithCorrectMetadata() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolume(root: root)

        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let (urlA, sizeA) = try makeSourceWAV(in: sourceDir, name: "a.wav")
        let (urlB, sizeB) = try makeSourceWAV(in: sourceDir, name: "b.wav")

        let trackA = wavSourceTrack(url: urlA, size: sizeA, title: "Track A", artist: "Artist One", album: "Album One", durationMS: 210) { track in
            track.genre = "Rock"
            track.composer = "Composer A"
            track.trackNumber = 1
            track.totalTracks = 10
            track.discNumber = 1
            track.totalDiscs = 1
            track.year = 1999
            track.albumArtist = "Album Artist One"
        }
        let trackB = wavSourceTrack(url: urlB, size: sizeB, title: "Track B", artist: "Artist Two", album: "Album Two", durationMS: 305)

        let plan = SyncPlan.compute(deviceTracks: [], sourceTracks: [trackA, trackB])
        #expect(plan.toAdd.count == 2)

        let report = try await SyncEngine.apply(plan: plan, to: volume)
        #expect(report.failures.isEmpty)
        #expect(report.added.count == 2)
        #expect(report.backup != nil)
        #expect(report.backup?.files.contains("iTunesDB") == true)

        // Reparse the database from disk (not the in-memory copy) to prove
        // the write round-trips.
        let reparsed = try ITunesDatabase(parsing: Data(contentsOf: volume.iTunesDBURL))
        #expect(reparsed.tracks.count == 2)

        let a = try #require(reparsed.tracks.first { $0.title == "Track A" })
        #expect(a.artist == "Artist One")
        #expect(a.album == "Album One")
        #expect(a.genre == "Rock")
        #expect(a.composer == "Composer A")
        #expect(a.trackNumber == 1)
        #expect(a.totalTracks == 10)
        #expect(a.discNumber == 1)
        #expect(a.totalDiscs == 1)
        #expect(a.year == 1999)
        #expect(a.size == UInt32(sizeA))
        #expect(a.length == 210)

        let b = try #require(reparsed.tracks.first { $0.title == "Track B" })
        #expect(b.artist == "Artist Two")
        #expect(b.size == UInt32(sizeB))

        // Master playlist references both new tracks.
        let master = try #require(reparsed.playlists.first { $0.id == Self.masterPlaylistID })
        // Keep these hoisted into locals. Inlining them as
        // `#expect(Set(master.trackIDsInOrder) == Set([a.uniqueID, b.uniqueID]))`
        // crashes the whole test process with EXC_BAD_ACCESS in objc_retain,
        // inside the #expect macro's own expression capture — it takes down
        // every other test in the run with it, not just this one.
        let masterTrackIDs: Set<UInt32> = Set(master.trackIDsInOrder)
        let expectedTrackIDs: Set<UInt32> = [a.uniqueID, b.uniqueID]
        #expect(masterTrackIDs == expectedTrackIDs)

        // Files actually landed on disk with the exact source bytes.
        for added in report.added {
            let destinationURL = DAPPath.url(forDAPPath: added.iPodPath, relativeTo: volume)
            #expect(FileManager.default.fileExists(atPath: destinationURL.path))
            let sourceURL = added.sourceFileURL
            #expect(try Data(contentsOf: destinationURL) == Data(contentsOf: sourceURL))
        }

        // The whole tree round-trips (structurally sound, not just field-correct).
        let reserialized = reparsed.serialized()
        let reparsedAgain = try ITunesDatabase(parsing: reserialized)
        #expect(reparsedAgain.tracks.count == 2)
    }

    // MARK: - Idempotence (full integration)

    @Test func syncingTheSameSourceTwiceProducesAnEmptySecondPlan() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolume(root: root)

        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let albumDir = sourceDir.appendingPathComponent("Some Artist - Some Album", isDirectory: true)
        try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)
        try SyntheticAudio.makeWAV(at: albumDir.appendingPathComponent("Some Artist - Track One.wav"))
        try SyntheticAudio.makeWAV(at: albumDir.appendingPathComponent("Some Artist - Track Two.wav"))

        let firstScan = try await LibraryScanner.scan(sourceFolder: sourceDir, model: volume.model)
        let firstPlan = SyncPlan.compute(deviceTracks: [], sourceTracks: firstScan)
        #expect(firstPlan.toAdd.count == 2)

        let firstReport = try await SyncEngine.apply(plan: firstPlan, to: volume)
        #expect(firstReport.failures.isEmpty)
        #expect(firstReport.added.count == 2)

        // Re-scan the identical, unchanged source folder and re-read the device.
        let secondScan = try await LibraryScanner.scan(sourceFolder: sourceDir, model: volume.model)
        let deviceTracksNow = try ITunesDatabase(parsing: Data(contentsOf: volume.iTunesDBURL)).tracks
        let secondPlan = SyncPlan.compute(deviceTracks: deviceTracksNow, sourceTracks: secondScan)

        #expect(secondPlan.toAdd.isEmpty)
        #expect(secondPlan.toRemove.isEmpty)
        #expect(secondPlan.unchanged.count == 2)
    }

    // MARK: - Removal

    @Test func removalDeletesFileAndCleansUpPlaylistEntry() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolume(root: root)

        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let (url, size) = try makeSourceWAV(in: sourceDir, name: "a.wav")
        let track = wavSourceTrack(url: url, size: size, title: "To Be Removed", artist: "Artist")

        let addPlan = SyncPlan.compute(deviceTracks: [], sourceTracks: [track])
        let addReport = try await SyncEngine.apply(plan: addPlan, to: volume)
        let added = try #require(addReport.added.first)
        let addedFileURL = DAPPath.url(forDAPPath: added.iPodPath, relativeTo: volume)
        #expect(FileManager.default.fileExists(atPath: addedFileURL.path))

        // Now sync against an empty source with removeMissing: true.
        let deviceTracksNow = try ITunesDatabase(parsing: Data(contentsOf: volume.iTunesDBURL)).tracks
        #expect(deviceTracksNow.count == 1)
        let removePlan = SyncPlan.compute(deviceTracks: deviceTracksNow, sourceTracks: [], selection: SyncSelection(removeMissing: true))
        #expect(removePlan.toRemove.count == 1)

        let removeReport = try await SyncEngine.apply(plan: removePlan, to: volume)
        #expect(removeReport.failures.isEmpty)
        #expect(removeReport.removed.count == 1)

        #expect(!FileManager.default.fileExists(atPath: addedFileURL.path))

        let finalDB = try ITunesDatabase(parsing: Data(contentsOf: volume.iTunesDBURL))
        #expect(finalDB.tracks.isEmpty)
        let master = try #require(finalDB.playlists.first { $0.id == Self.masterPlaylistID })
        #expect(master.trackIDsInOrder.isEmpty)
    }

    // MARK: - Cancellation

    @Test func cancellationDuringAddLeavesNoOrphanedFilesAndDatabaseUntouched() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolume(root: root)

        let originalDBData = try Data(contentsOf: volume.iTunesDBURL)
        let beforeListing = SyntheticDAP.musicFileListing(volume)

        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        // A handful of moderately-sized files, so the copy loop has more
        // than one chance to observe cancellation mid-flight.
        var tracks: [SourceTrack] = []
        for i in 0..<12 {
            let (url, size) = try makeSourceWAV(in: sourceDir, name: "track\(i).wav", durationSeconds: 2.0)
            tracks.append(wavSourceTrack(url: url, size: size, title: "Track \(i)", artist: "Artist"))
        }
        let plan = SyncPlan.compute(deviceTracks: [], sourceTracks: tracks)
        #expect(plan.toAdd.count == 12)

        // Cancellation is triggered from the progress callback rather than
        // after a sleep. A fixed delay is a race the test loses on a fast
        // disk — 12 small files can copy in full before a 2ms timer fires,
        // and then nothing is being cancelled at all. Firing on a specific
        // file makes the moment exact.
        let canceller = Canceller()
        let task = Task {
            try await SyncEngine.apply(plan: plan, to: volume) { progress in
                if case .copying(let fileIndex, _) = progress.phase, fileIndex == 3 {
                    canceller.requestCancel()
                }
            }
        }
        canceller.adopt(task)
        let report = try await task.value

        #expect(report.cancelled)
        // Whatever the timing — cancellation can land after any number of
        // files have copied, including all of them — a cancelled sync must
        // report no additions, because the rollback deleted them and the
        // database was never written.
        #expect(report.added.isEmpty)

        // No orphaned files: the music folders look exactly as they did
        // before this sync started.
        let afterListing = SyntheticDAP.musicFileListing(volume)
        #expect(afterListing == beforeListing)

        // The database was never rewritten.
        let afterDBData = try Data(contentsOf: volume.iTunesDBURL)
        #expect(afterDBData == originalDBData)
    }

    // MARK: - Partial failure

    @Test func aSingleFailingFileDoesNotAbortTheRestOfTheSync() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolume(root: root)

        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let (goodURL, goodSize) = try makeSourceWAV(in: sourceDir, name: "good.wav")
        let goodTrack = wavSourceTrack(url: goodURL, size: goodSize, title: "Good", artist: "Artist")

        // A SourceTrack pointing at a file that doesn't actually exist on
        // disk (as if it vanished between scan and sync).
        let missingURL = sourceDir.appendingPathComponent("missing.wav")
        let badTrack = wavSourceTrack(url: missingURL, size: 12_345, title: "Bad", artist: "Artist")

        let plan = SyncPlan.compute(deviceTracks: [], sourceTracks: [goodTrack, badTrack])
        #expect(plan.toAdd.count == 2)

        let report = try await SyncEngine.apply(plan: plan, to: volume)
        #expect(report.added.count == 1)
        #expect(report.added.first?.sourceFileURL == goodURL)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.sourceFileURL == missingURL)

        let reparsed = try ITunesDatabase(parsing: Data(contentsOf: volume.iTunesDBURL))
        #expect(reparsed.tracks.count == 1)
        #expect(reparsed.tracks.first?.title == "Good")
    }

    // MARK: - Error reporting

    @Test func copyFailuresNameWhichHalfOfTheCopyFailed() throws {
        let readFailure = CopyError(
            step: .openingSource,
            path: "/Users/someone/Music/song.mp3",
            underlying: CocoaError(.fileReadNoPermission)
        )
        let message = try #require(readFailure.errorDescription)
        // The distinction that matters: losing access to the source needs a
        // different fix from failing to write to the iPod, and a bare
        // "permission denied" sends you to the wrong one.
        #expect(message.contains("read the source file"))
        #expect(message.contains("/Users/someone/Music/song.mp3"))

        let writeFailure = CopyError(step: .openingDestination, path: "/Volumes/POD/F00/ABCD.mp3", underlying: nil)
        let writeMessage = try #require(writeFailure.errorDescription)
        #expect(writeMessage.contains("write to the file on the DAP"))
    }

    @Test func reportedFailuresUseTheErrorsOwnWordingNotItsDebugDump() throws {
        // String(describing:) on an NSError dumps domain/code/userInfo,
        // which is what the user would otherwise be shown.
        let underlying = CocoaError(.fileWriteNoPermission)
        let described = SyncEngine.describe(CopyError(step: .transferring, path: "/tmp/x.mp3", underlying: underlying))
        #expect(described.contains("NSCocoaErrorDomain") == false)
        #expect(described.contains("copy the file's contents"))

        // A plain error with no written description still yields something.
        struct Bare: Error {}
        #expect(SyncEngine.describe(Bare()).isEmpty == false)
    }

    // MARK: - Failed copies leave nothing behind

    @Test func aSourceFileThatCannotBeReadLeavesNoEmptyFileOnTheDevice() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolume(root: root)

        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sourceDir.appendingPathComponent("locked.wav").path)
            try? FileManager.default.removeItem(at: sourceDir)
        }

        let (goodURL, goodSize) = try makeSourceWAV(in: sourceDir, name: "good.wav")
        let (lockedURL, lockedSize) = try makeSourceWAV(in: sourceDir, name: "locked.wav")
        // Unreadable, the way a sandboxed host sees a source file whose
        // security scope has lapsed. The engine creates its destination file
        // before it discovers it can't read the source, so this is exactly
        // the path that used to strand a zero-byte file on the device.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedURL.path)

        let before = SyntheticDAP.musicFileListing(volume)
        let plan = SyncPlan.compute(
            deviceTracks: [],
            sourceTracks: [
                wavSourceTrack(url: goodURL, size: goodSize, title: "Good", artist: "A"),
                wavSourceTrack(url: lockedURL, size: lockedSize, title: "Locked", artist: "A"),
            ]
        )

        let report = try await SyncEngine.apply(plan: plan, to: volume)

        #expect(report.added.count == 1)
        #expect(report.failures.count == 1)
        let message = try #require(report.failures.first?.message)
        #expect(message.contains("read the source file"))

        // Exactly one new file on the device: the one that copied. The
        // failed one must not have left its pre-created destination behind,
        // because nothing references it and nothing would ever clean it up.
        let after = SyntheticDAP.musicFileListing(volume)
        let added = after.subtracting(before)
        #expect(added.count == 1)

        // And that file is the real one, not an empty husk.
        let addedPath = try #require(added.first)
        let size = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(addedPath).path)[.size] as? Int
        #expect(size == Int(goodSize))
    }

    @Test func syncSweepsAppleDoubleSidecarsFromTheControlDirectory() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolume(root: root)

        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let (url, size) = try makeSourceWAV(in: sourceDir, name: "a.wav")

        // Stand in for a sidecar macOS stamped after a per-write strip
        // already ran — under App Sandbox the provenance xattr can land late,
        // which is how a sandboxed sync left one beside every track it
        // copied. (The sidecar is a plain file here: only a real FAT32 volume
        // materializes them for real, which FAT32Scratch covers separately.)
        let stray = volume.musicDirectory.appendingPathComponent("F00/._STRAY.mp3")
        FileManager.default.createFile(atPath: stray.path, contents: Data([0]))
        let strayInITunes = volume.iTunesDirectory.appendingPathComponent("._iTunesDB")
        FileManager.default.createFile(atPath: strayInITunes.path, contents: Data([0]))

        let plan = SyncPlan.compute(
            deviceTracks: [],
            sourceTracks: [wavSourceTrack(url: url, size: size, title: "A", artist: "B")]
        )
        _ = try await SyncEngine.apply(plan: plan, to: volume)

        #expect(FileManager.default.fileExists(atPath: stray.path) == false)
        #expect(FileManager.default.fileExists(atPath: strayInITunes.path) == false)
    }
}
