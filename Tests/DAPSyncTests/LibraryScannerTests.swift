import Foundation
import Testing
import DAPDevice
@testable import DAPSync

@Suite struct LibraryScannerTests {
    private static let mini2gModel = DeviceModel(
        displayName: "iPod mini (2nd generation)",
        generation: "mini 2G",
        family: .mini,
        requiresDatabaseSignature: .none,
        supportsArtwork: false,
        musicFolderCount: 50
    )

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func scanFallsBackToFilenameAndFolderNamingWhenTagsAreMissing() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let albumDir = root.appendingPathComponent("Some Artist - Some Album", isDirectory: true)
        try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)
        let fileURL = albumDir.appendingPathComponent("Some Artist - Some Title.wav")
        try SyntheticAudio.makeWAV(at: fileURL)

        let tracks = try await LibraryScanner.scan(sourceFolder: root, model: Self.mini2gModel)
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)
        #expect(track.title == "Some Title")
        #expect(track.artist == "Some Artist")
        #expect(track.album == "Some Album")
        #expect(track.durationMS > 0)
        if case .passThrough(let format) = track.compatibility {
            #expect(format.kind == .wav)
        } else {
            Issue.record("expected passThrough")
        }
    }

    @Test func scanExtractsEmbeddedMetadataFromAAC() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("track.m4a")
        try await SyntheticAudio.makeAAC(at: fileURL, tags: SyntheticAudio.Tags(
            title: "Embedded Title",
            artist: "Embedded Artist",
            album: "Embedded Album",
            albumArtist: "Embedded Album Artist",
            genre: "Electronic",
            composer: "Embedded Composer",
            trackNumber: 3,
            totalTracks: 12,
            discNumber: 1,
            totalDiscs: 2,
            year: 2004,
            compilation: true
        ))

        let tracks = try await LibraryScanner.scan(sourceFolder: root, model: Self.mini2gModel)
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)

        #expect(track.title == "Embedded Title")
        #expect(track.artist == "Embedded Artist")
        #expect(track.album == "Embedded Album")
        #expect(track.albumArtist == "Embedded Album Artist")
        #expect(track.genre == "Electronic")
        #expect(track.composer == "Embedded Composer")
        #expect(track.trackNumber == 3)
        #expect(track.totalTracks == 12)
        #expect(track.discNumber == 1)
        #expect(track.totalDiscs == 2)
        #expect(track.year == 2004)
        #expect(track.isCompilation == true)
        #expect(track.durationMS > 0)

        if case .passThrough(let format) = track.compatibility {
            #expect(format.kind == .aac)
        } else {
            Issue.record("expected passThrough, got \(track.compatibility)")
        }
    }

    @Test func scanSkipsNonAudioFilesSilently() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try SyntheticAudio.makeWAV(at: root.appendingPathComponent("Real Artist - Real Title.wav"))
        try Data("not a real lyric file, just bytes".utf8).write(to: root.appendingPathComponent("Real Artist - Real Title.lrc"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent("cover.jpg"))
        try Data("#EXTM3U\n".utf8).write(to: root.appendingPathComponent("playlist.m3u"))

        let tracks = try await LibraryScanner.scan(sourceFolder: root, model: Self.mini2gModel)
        #expect(tracks.count == 1)
        #expect(tracks.first?.fileURL.pathExtension == "wav")
    }

    @Test func scanReportsDiscoveredAndProcessedCounts() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 0..<3 {
            try SyntheticAudio.makeWAV(at: root.appendingPathComponent("Artist - Track \(i).wav"))
        }

        let collector = ProgressCollector()
        let tracks = try await LibraryScanner.scan(sourceFolder: root, model: Self.mini2gModel) { progress in
            collector.add(progress)
        }

        let progressUpdates = collector.snapshot()
        #expect(tracks.count == 3)
        #expect(progressUpdates.first?.filesDiscovered == 3)
        #expect(progressUpdates.last?.filesProcessed == 3)
    }

    @Test func scanIsCancellable() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 0..<5 {
            try SyntheticAudio.makeWAV(at: root.appendingPathComponent("Artist - Track \(i).wav"))
        }

        let task = Task {
            try await LibraryScanner.scan(sourceFolder: root, model: Self.mini2gModel)
        }
        task.cancel()

        do {
            _ = try await task.value
            // Cancellation is checked between files, so it's possible (if
            // unlikely) the whole scan raced ahead of the cancel; either
            // outcome is acceptable as long as it doesn't crash or hang.
        } catch is CancellationError {
            // Expected outcome.
        }
    }

    // MARK: - Real hardware smoke test

    private func firstRealSourceFiles(limit: Int) -> [URL] {
        let realRoot = URL(fileURLWithPath: "/Volumes/JOHNREYES'S/Music", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: realRoot, includingPropertiesForKeys: nil) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext == "mp3" || ext == "m4a" {
                result.append(url)
            }
            if result.count >= limit { break }
        }
        return result
    }

    @Test func scanningRealDeviceFilesProducesReasonableMetadata() async throws {
        let sampleSourceFiles = firstRealSourceFiles(limit: 4)
        guard !sampleSourceFiles.isEmpty else { return }

        let sampleDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sampleDir) }
        for source in sampleSourceFiles {
            try FileManager.default.copyItem(at: source, to: sampleDir.appendingPathComponent(source.lastPathComponent))
        }

        let tracks = try await LibraryScanner.scan(sourceFolder: sampleDir, model: Self.mini2gModel)
        #expect(tracks.count == sampleSourceFiles.count)
        for track in tracks {
            #expect(!track.title.isEmpty)
            #expect(track.durationMS > 0)
            if case .unsupported(let reason) = track.compatibility {
                Issue.record("real device file \(track.fileURL.lastPathComponent) unexpectedly unsupported: \(reason)")
            }
        }
    }
}
