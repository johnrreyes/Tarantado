import Foundation
import Testing
import DAPDB
import DAPDevice
@testable import DAPSync

/// Integration tests for Phase 3: `SyncEngine` writing `ArtworkDB` and
/// `.ithmb` files alongside `iTunesDB`. Separate from `SyncEngineTests.swift`
/// to keep that file's already-large surface focused on the non-artwork
/// path; this file is specifically about the artwork wiring.
@Suite struct SyncEngineArtworkTests {
    /// A synthetic volume identified as an artwork-capable 5G, the same way
    /// `SyncEngineTests.refusesDeviceRequiringDatabaseSignature` overrides
    /// the model to test a capability this library doesn't otherwise
    /// exercise on the mini 2G fixture everything else builds on.
    private func makeArtworkCapableVolume(root: URL) throws -> DAPVolume {
        let base = try DAPVolume.validate(at: root)
        let artworkModel = DeviceModel(
            displayName: "iPod (5th generation, \"video\")",
            generation: "iPod 5G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .none,
            supportsArtwork: true,
            musicFolderCount: 50,
            playlistSectionType: 3
        )
        return DAPVolume(rootURL: base.rootURL, sysInfo: base.sysInfo, model: artworkModel)
    }

    private func makeSourceWAV(in dir: URL, name: String) throws -> (url: URL, size: Int64) {
        let url = dir.appendingPathComponent(name)
        try SyntheticAudio.makeWAV(at: url)
        let size = try Int64((FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        return (url, size)
    }

    private func wavSourceTrack(
        url: URL, size: Int64, title: String, artist: String, artworkData: Data? = nil
    ) -> SourceTrack {
        SourceTrack(
            fileURL: url,
            fileSize: size,
            title: title,
            artist: artist,
            durationMS: 200,
            artworkData: artworkData,
            compatibility: .passThrough(SourceAudioFormat(kind: .wav, filetypeMarker: 0x2056_4157, filetypeString: "WAV audio file"))
        )
    }

    private func makeTempSourceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Writing artwork

    @Test func syncingATrackWithArtworkWritesArtworkDBAndIthmbFiles() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeArtworkCapableVolume(root: root)

        let sourceDir = try makeTempSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let (url, size) = try makeSourceWAV(in: sourceDir, name: "a.wav")
        let artwork = SyntheticImage.makeJPEG(width: 400, height: 400)

        let plan = SyncPlan.compute(
            deviceTracks: [],
            sourceTracks: [wavSourceTrack(url: url, size: size, title: "Has Art", artist: "Artist", artworkData: artwork)]
        )
        let report = try await SyncEngine.apply(plan: plan, to: volume)
        #expect(report.failures.isEmpty)
        #expect(report.added.count == 1)

        let reparsedDB = try ITunesDatabase(parsing: Data(contentsOf: volume.iTunesDBURL))
        let track = try #require(reparsedDB.trackChunks.compactMap(MHIT.init).first)
        #expect(track.hasArtwork == 1)
        #expect(track.artworkCount == 1)
        #expect(track.artworkSize == UInt32(artwork.count))

        #expect(FileManager.default.fileExists(atPath: volume.artworkDBURL.path))
        let artworkDB = try ArtworkDatabase(parsing: Data(contentsOf: volume.artworkDBURL))
        #expect(artworkDB.images.count == 1)
        let image = try #require(artworkDB.images.first)
        #expect(image.songID == track.dbid)
        #expect(image.origImageSize == UInt32(artwork.count))

        let thumbnails = image.thumbnails
        #expect(Set(thumbnails.map(\.formatID)) == [1028, 1029])
        for thumbnail in thumbnails {
            let expectedFormat = ArtworkEncoder.ipod5GFormats.first { $0.formatID == thumbnail.formatID }!
            #expect(thumbnail.imageSize == UInt32(expectedFormat.width * expectedFormat.height * 2))
            let ithmbURL = volume.artworkDirectory.appendingPathComponent(thumbnail.ithmbFileName!.replacingOccurrences(of: ":", with: ""))
            let ithmbData = try Data(contentsOf: ithmbURL)
            #expect(UInt32(ithmbData.count) >= thumbnail.ithmbOffset + thumbnail.imageSize)
        }

        // Structural round trip, same standard the rest of this module holds
        // every write to.
        let reserializedArt = artworkDB.serialized()
        #expect(try ArtworkDatabase(parsing: reserializedArt).serialized() == reserializedArt)
    }

    @Test func identicalArtworkAcrossTracksIsEncodedAndWrittenOnlyOnce() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeArtworkCapableVolume(root: root)

        let sourceDir = try makeTempSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let (urlA, sizeA) = try makeSourceWAV(in: sourceDir, name: "a.wav")
        let (urlB, sizeB) = try makeSourceWAV(in: sourceDir, name: "b.wav")
        // Same bytes, standing in for two tracks off the same album sharing
        // one embedded cover.
        let sharedArtwork = SyntheticImage.makeJPEG(width: 400, height: 400)

        let plan = SyncPlan.compute(
            deviceTracks: [],
            sourceTracks: [
                wavSourceTrack(url: urlA, size: sizeA, title: "Track A", artist: "Artist", artworkData: sharedArtwork),
                wavSourceTrack(url: urlB, size: sizeB, title: "Track B", artist: "Artist", artworkData: sharedArtwork),
            ]
        )
        let report = try await SyncEngine.apply(plan: plan, to: volume)
        #expect(report.failures.isEmpty)
        #expect(report.added.count == 2)

        let artworkDB = try ArtworkDatabase(parsing: Data(contentsOf: volume.artworkDBURL))
        #expect(artworkDB.images.count == 2) // one mhii per track, still

        let largeThumbnails = artworkDB.images.compactMap { $0.thumbnail(formatID: 1029) }
        #expect(largeThumbnails.count == 2)
        // Both point at the exact same .ithmb bytes.
        #expect(largeThumbnails[0].ithmbFileName == largeThumbnails[1].ithmbFileName)
        #expect(largeThumbnails[0].ithmbOffset == largeThumbnails[1].ithmbOffset)

        // And the file itself holds exactly one copy of the pixel data, not two.
        let ithmbURL = volume.artworkDirectory.appendingPathComponent("F1029_1.ithmb")
        let ithmbData = try Data(contentsOf: ithmbURL)
        #expect(ithmbData.count == 200 * 200 * 2)
    }

    // MARK: - Removal

    @Test func removingATrackWithArtworkRemovesItsArtworkDBEntry() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeArtworkCapableVolume(root: root)

        let sourceDir = try makeTempSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let (url, size) = try makeSourceWAV(in: sourceDir, name: "a.wav")
        let artwork = SyntheticImage.makeJPEG(width: 200, height: 200)

        let addPlan = SyncPlan.compute(
            deviceTracks: [],
            sourceTracks: [wavSourceTrack(url: url, size: size, title: "To Remove", artist: "Artist", artworkData: artwork)]
        )
        _ = try await SyncEngine.apply(plan: addPlan, to: volume)
        #expect(try ArtworkDatabase(parsing: Data(contentsOf: volume.artworkDBURL)).images.count == 1)

        let deviceTracksNow = try ITunesDatabase(parsing: Data(contentsOf: volume.iTunesDBURL)).tracks
        let removePlan = SyncPlan.compute(deviceTracks: deviceTracksNow, sourceTracks: [], selection: SyncSelection(removeMissing: true))
        let removeReport = try await SyncEngine.apply(plan: removePlan, to: volume)
        #expect(removeReport.removed.count == 1)

        let artworkDBAfter = try ArtworkDatabase(parsing: Data(contentsOf: volume.artworkDBURL))
        #expect(artworkDBAfter.images.isEmpty)
    }

    // MARK: - Soft failure

    @Test func undecodableArtworkStillSyncsTheTrackWithoutIt() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeArtworkCapableVolume(root: root)

        let sourceDir = try makeTempSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let (url, size) = try makeSourceWAV(in: sourceDir, name: "a.wav")

        let plan = SyncPlan.compute(
            deviceTracks: [],
            sourceTracks: [wavSourceTrack(url: url, size: size, title: "Bad Art", artist: "Artist", artworkData: Data([0x00, 0x01]))]
        )
        let report = try await SyncEngine.apply(plan: plan, to: volume)
        #expect(report.failures.isEmpty)
        #expect(report.added.count == 1)

        let track = try #require(
            try ITunesDatabase(parsing: Data(contentsOf: volume.iTunesDBURL)).trackChunks.compactMap(MHIT.init).first
        )
        #expect(track.hasArtwork == 2)
        #expect(track.artworkCount == 0)
    }

    // MARK: - Devices this feature must never touch

    @Test func nonArtworkCapableDeviceNeverWritesAnArtworkDB() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        // The default fixture model (mini 2G) — supportsArtwork == false.
        let volume = try DAPVolume.validate(at: root)
        #expect(volume.model.supportsArtwork == false)

        let sourceDir = try makeTempSourceDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let (url, size) = try makeSourceWAV(in: sourceDir, name: "a.wav")
        let artwork = SyntheticImage.makeJPEG(width: 100, height: 100)

        let plan = SyncPlan.compute(
            deviceTracks: [],
            sourceTracks: [wavSourceTrack(url: url, size: size, title: "Has Art", artist: "Artist", artworkData: artwork)]
        )
        let report = try await SyncEngine.apply(plan: plan, to: volume)
        #expect(report.failures.isEmpty)
        #expect(report.added.count == 1)

        #expect(FileManager.default.fileExists(atPath: volume.artworkDBURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: volume.artworkDirectory.path) == false)

        let track = try #require(
            try ITunesDatabase(parsing: Data(contentsOf: volume.iTunesDBURL)).trackChunks.compactMap(MHIT.init).first
        )
        // Untouched -- exactly the pre-artwork-feature behavior.
        #expect(track.hasArtwork == 0)
        #expect(track.artworkCount == 0)
        #expect(track.artworkSize == 0)
    }
}
