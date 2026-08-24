import Foundation
import AVFoundation
import CoreMedia
import DAPDevice

/// One audio file found in a source folder, with metadata extracted and its
/// device compatibility already classified.
public struct SourceTrack: Sendable, Equatable, Identifiable {
    public var id: URL { fileURL }

    public let fileURL: URL
    public let fileSize: Int64

    public var title: String
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var genre: String?
    public var composer: String?
    public var trackNumber: Int?
    public var totalTracks: Int?
    public var discNumber: Int?
    public var totalDiscs: Int?
    public var year: Int?
    /// Duration, in milliseconds (matches `MHIT.length`'s units).
    public var durationMS: Int
    public var bitrateKbps: Int?
    public var sampleRateHz: Int?
    public var isCompilation: Bool

    public var compatibility: AudioCompatibility

    public init(
        fileURL: URL,
        fileSize: Int64,
        title: String,
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        composer: String? = nil,
        trackNumber: Int? = nil,
        totalTracks: Int? = nil,
        discNumber: Int? = nil,
        totalDiscs: Int? = nil,
        year: Int? = nil,
        durationMS: Int,
        bitrateKbps: Int? = nil,
        sampleRateHz: Int? = nil,
        isCompilation: Bool = false,
        compatibility: AudioCompatibility
    ) {
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.genre = genre
        self.composer = composer
        self.trackNumber = trackNumber
        self.totalTracks = totalTracks
        self.discNumber = discNumber
        self.totalDiscs = totalDiscs
        self.year = year
        self.durationMS = durationMS
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.isCompilation = isCompilation
        self.compatibility = compatibility
    }
}

/// Recursively scans a source folder for audio files, extracting metadata
/// and classifying device compatibility for each.
public enum LibraryScanner {
    /// Extensions worth attempting to open as audio. Anything else (`.lrc`,
    /// `.jpg`, `.m3u`, `.plist`, ...) is skipped without ever touching
    /// AVFoundation. This is deliberately broader than
    /// `AudioCompatibilityChecker`'s supported set — FLAC/OGG/Opus/WMA are
    /// listed here so they get opened, classified, and reported as
    /// `.unsupported` with a reason, rather than silently vanishing as if
    /// they were never seen.
    public static let candidateExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "m4p", "aac",
        "wav", "wave", "aiff", "aif", "aifc",
        "flac", "ogg", "oga", "opus", "wma",
    ]

    public struct Progress: Sendable, Equatable {
        public var filesDiscovered: Int
        public var filesProcessed: Int
        public var currentFileName: String?
    }

    /// Walks `sourceFolder` recursively and returns one `SourceTrack` per
    /// audio file found. Cancellable: checks `Task.isCancelled` between
    /// files and throws `CancellationError` promptly rather than finishing
    /// the whole tree first.
    public static func scan(
        sourceFolder: URL,
        model: DeviceModel,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> [SourceTrack] {
        let candidates = try enumerateCandidates(in: sourceFolder)
        progress?(Progress(filesDiscovered: candidates.count, filesProcessed: 0, currentFileName: nil))

        var results: [SourceTrack] = []
        results.reserveCapacity(candidates.count)
        for (index, url) in candidates.enumerated() {
            try Task.checkCancellation()
            let track = await scanOne(url: url, model: model)
            results.append(track)
            progress?(Progress(filesDiscovered: candidates.count, filesProcessed: index + 1, currentFileName: url.lastPathComponent))
        }
        return results
    }

    // MARK: - Enumeration

    private static func enumerateCandidates(in sourceFolder: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: sourceFolder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard candidateExtensions.contains(ext) else { continue }

            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }

            // iCloud placeholder: not downloaded to this device yet. Kick
            // off the download for next time rather than treating this as a
            // failure, and skip it for this scan pass.
            if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                continue
            }

            candidates.append(url)
        }
        return candidates
    }

    // MARK: - Per-file scan

    private static func scanOne(url: URL, model: DeviceModel) async -> SourceTrack {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0)
        let compatibility = await AudioCompatibilityChecker.classify(fileURL: url, fileSize: fileSize, model: model)

        let asset = AVURLAsset(url: url)

        var durationMS = 0
        var bitrateKbps: Int?
        var sampleRateHz: Int?
        var metadataItems: [AVMetadataItem] = []

        if let duration = try? await asset.load(.duration), duration.isNumeric {
            durationMS = max(0, Int((duration.seconds * 1000).rounded()))
        }
        metadataItems = (try? await asset.load(.metadata)) ?? []

        if let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first {
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                bitrateKbps = Int((rate / 1000).rounded())
            }
            if let formatDescriptions = try? await track.load(.formatDescriptions),
               let formatDescription = formatDescriptions.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
                sampleRateHz = Int(asbd.pointee.mSampleRate.rounded())
            }
        }

        let extracted = await MetadataExtractor.extract(from: metadataItems)
        let fallback = FilenameFallback.derive(fileURL: url)

        return SourceTrack(
            fileURL: url,
            fileSize: fileSize,
            title: nonEmpty(extracted.title) ?? fallback.title,
            artist: nonEmpty(extracted.artist) ?? fallback.artist,
            albumArtist: nonEmpty(extracted.albumArtist) ?? nonEmpty(extracted.artist) ?? fallback.artist,
            album: nonEmpty(extracted.album) ?? fallback.album,
            genre: nonEmpty(extracted.genre),
            composer: nonEmpty(extracted.composer),
            trackNumber: extracted.trackNumber,
            totalTracks: extracted.totalTracks,
            discNumber: extracted.discNumber,
            totalDiscs: extracted.totalDiscs,
            year: extracted.year,
            durationMS: durationMS,
            bitrateKbps: bitrateKbps,
            sampleRateHz: sampleRateHz,
            isCompilation: extracted.isCompilation,
            compatibility: compatibility
        )
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

// MARK: - Filename fallback

/// When tag data is missing, falls back to the real library's own naming
/// convention: `Artist - Title.mp3` files inside `Artist - Album/` folders.
enum FilenameFallback {
    struct Result {
        var title: String
        var artist: String?
        var album: String?
    }

    static func derive(fileURL: URL) -> Result {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        var title = stem
        var artist: String?

        if let range = stem.range(of: " - ") {
            let candidateArtist = String(stem[stem.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let candidateTitle = String(stem[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !candidateArtist.isEmpty, !candidateTitle.isEmpty {
                artist = candidateArtist
                title = candidateTitle
            }
        }

        var album: String?
        let parent = fileURL.deletingLastPathComponent().lastPathComponent
        if let range = parent.range(of: " - ") {
            let parentArtist = String(parent[parent.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let parentAlbum = String(parent[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !parentArtist.isEmpty, !parentAlbum.isEmpty {
                album = parentAlbum
                if artist == nil { artist = parentArtist }
            }
        }

        return Result(title: title, artist: artist, album: album)
    }
}

// MARK: - Metadata extraction

/// Pulls common fields out of an `AVAsset`'s metadata items, trying
/// container-agnostic "common" identifiers first, then falling back to
/// format-specific ones (ID3 for MP3, iTunes MP4 atoms for M4A/M4B).
enum MetadataExtractor {
    struct Extracted {
        var title: String?
        var artist: String?
        var albumArtist: String?
        var album: String?
        var genre: String?
        var composer: String?
        var trackNumber: Int?
        var totalTracks: Int?
        var discNumber: Int?
        var totalDiscs: Int?
        var year: Int?
        var isCompilation = false
    }

    static func extract(from items: [AVMetadataItem]) async -> Extracted {
        var result = Extracted()

        result.title = await firstString(items, [.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName])
        result.artist = await firstString(items, [.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist])
        result.albumArtist = await firstString(items, [.iTunesMetadataAlbumArtist])
        result.album = await firstString(items, [.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum])
        result.genre = await firstString(items, [.id3MetadataContentType, .iTunesMetadataUserGenre])
        result.composer = await firstString(items, [.id3MetadataComposer, .iTunesMetadataComposer, .commonIdentifierAuthor])

        if let (track, total) = await numberPair(items, .iTunesMetadataTrackNumber) {
            result.trackNumber = track
            result.totalTracks = total
        } else if let text = await firstString(items, [.id3MetadataTrackNumber]) {
            (result.trackNumber, result.totalTracks) = parseFraction(text)
        }

        if let (disc, total) = await numberPair(items, .iTunesMetadataDiscNumber) {
            result.discNumber = disc
            result.totalDiscs = total
        } else if let text = await firstString(items, [.id3MetadataPartOfASet]) {
            (result.discNumber, result.totalDiscs) = parseFraction(text)
        }

        if let text = await firstString(items, [.id3MetadataRecordingTime, .id3MetadataYear, .iTunesMetadataReleaseDate, .commonIdentifierCreationDate]) {
            result.year = Int(text.prefix(4))
        }

        result.isCompilation = await boolValue(items, .iTunesMetadataDiscCompilation)

        return result
    }

    private static func firstString(_ items: [AVMetadataItem], _ identifiers: [AVMetadataIdentifier]) async -> String? {
        for identifier in identifiers {
            let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
            guard let item = matches.first else { continue }
            if let value = try? await item.load(.stringValue), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Parses the binary "trkn"/"disk" iTunes MP4 atom payload: two
    /// reserved bytes, a big-endian `UInt16` index, a big-endian `UInt16`
    /// total, then two more reserved bytes.
    private static func numberPair(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) async -> (Int, Int)? {
        let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
        guard let item = matches.first else { return nil }
        guard let data = try? await item.load(.dataValue), data.count >= 6 else { return nil }
        let index = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
        let total = Int(data[data.startIndex + 4]) << 8 | Int(data[data.startIndex + 5])
        guard index > 0 || total > 0 else { return nil }
        return (index > 0 ? index : 0, total > 0 ? total : 0)
    }

    private static func boolValue(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) async -> Bool {
        let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
        guard let item = matches.first else { return false }
        if let number = try? await item.load(.numberValue) {
            return number.boolValue
        }
        return false
    }

    /// Parses ID3-style "3/12" track/disc strings.
    private static func parseFraction(_ text: String) -> (Int?, Int?) {
        let parts = text.split(separator: "/", maxSplits: 1)
        guard let first = parts.first, let index = Int(first.trimmingCharacters(in: .whitespaces)) else {
            return (nil, nil)
        }
        var total: Int?
        if parts.count > 1 {
            total = Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return (index, total)
    }
}
