import Foundation
import Testing
import DAPDB
import DAPDevice
import DAPSync
@testable import DAPUI

/// The model's playlist and removal operations, driven against a real
/// synthetic volume so each one is asserted by re-reading the device rather
/// than by inspecting in-memory state the operation just set.
@Suite struct LibraryEditingTests {
    @MainActor
    private func connectedModel(root: URL) async throws -> AppModel {
        let model = AppModel(localLibrary: nil)
        await model.connect(to: root)
        #expect(model.isConnected)
        return model
    }

    /// Puts real audio on the synthetic device so playlists have something
    /// to hold. Returns the allocated track IDs in order.
    @MainActor
    private func seed(_ model: AppModel, count: Int, sourceDirectory: URL) async throws -> [UInt32] {
        var sources: [SourceTrack] = []
        for index in 0..<count {
            let url = sourceDirectory.appendingPathComponent("t\(index).wav")
            try writeWAV(to: url)
            let size = Int64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
            sources.append(SourceTrack(
                fileURL: url,
                fileSize: size,
                title: "Track \(index)",
                artist: "Artist \(index)",
                durationMS: 200,
                compatibility: .passThrough(SourceAudioFormat(kind: .wav, filetypeMarker: 0x2056_4157, filetypeString: "WAV audio file"))
            ))
        }
        let volume = try #require(model.volume)
        let plan = SyncPlan.compute(deviceTracks: [], sourceTracks: sources)
        let report = try await SyncEngine.apply(plan: plan, to: volume)
        #expect(report.failures.isEmpty)
        await model.refreshDeviceInfo()
        return report.added.map(\.uniqueID)
    }

    private func makeSourceDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Playlist visibility

    @MainActor
    @Test func editablePlaylistsExcludeTheMasterAndSmartPlaylists() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let model = try await connectedModel(root: root)

        // The fixture ships a master playlist (mirrored across two sections)
        // and two smart playlists. None of them may be offered for editing.
        #expect(model.devicePlaylists.isEmpty == false)
        #expect(model.editablePlaylists.isEmpty)

        await model.createPlaylist(title: "Mine")
        #expect(model.editState == .idle)
        #expect(model.editablePlaylists.map(\.title) == ["Mine"])
    }

    // MARK: - Create / rename / delete

    @MainActor
    @Test func createRenameAndDeleteRoundTripThroughTheDevice() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDir = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let model = try await connectedModel(root: root)
        let trackIDs = try await seed(model, count: 2, sourceDirectory: sourceDir)

        await model.createPlaylist(title: "First", trackIDs: trackIDs)
        let created = try #require(model.editablePlaylists.first)
        #expect(created.trackIDsInOrder == trackIDs)

        await model.renamePlaylist(id: created.id, to: "Second")
        #expect(model.editablePlaylists.first?.title == "Second")

        await model.deletePlaylist(id: created.id)
        #expect(model.editablePlaylists.isEmpty)
        // Deleting a playlist must not delete its tracks.
        #expect(model.deviceTracks.count == 2)
    }

    // MARK: - Membership and order

    @MainActor
    @Test func addingAndRemovingTracksUpdatesThePlaylistOnDisk() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDir = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let model = try await connectedModel(root: root)
        let trackIDs = try await seed(model, count: 3, sourceDirectory: sourceDir)

        await model.createPlaylist(title: "Growing", trackIDs: [trackIDs[0]])
        let playlist = try #require(model.editablePlaylists.first)

        await model.addTracks([trackIDs[1], trackIDs[2]], toPlaylistID: playlist.id)
        let afterAdd = try #require(model.editablePlaylists.first)
        #expect(afterAdd.trackIDsInOrder == trackIDs)

        await model.removeTracks([trackIDs[1]], fromPlaylistID: playlist.id)
        let afterRemove = try #require(model.editablePlaylists.first)
        let expected = [trackIDs[0], trackIDs[2]]
        #expect(afterRemove.trackIDsInOrder == expected)
        // Removing from a playlist leaves the tracks themselves alone.
        #expect(model.deviceTracks.count == 3)
    }

    @MainActor
    @Test func reorderingMovesTheEntriesTheFirmwareActuallyReads() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDir = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let model = try await connectedModel(root: root)
        let trackIDs = try await seed(model, count: 3, sourceDirectory: sourceDir)
        await model.createPlaylist(title: "Ordered", trackIDs: trackIDs)
        let playlist = try #require(model.editablePlaylists.first)

        let reversed = Array(trackIDs.reversed())
        await model.reorderPlaylist(id: playlist.id, trackIDsInOrder: reversed)

        // Re-read the chunk tree rather than trusting the model's own view:
        // the device reads the physical order of the mhip entries, and a
        // reorder that only rewrote position fields displayed unchanged on
        // real hardware.
        let volume = try #require(model.volume)
        let db = try ITunesDatabase(parsing: try Data(contentsOf: volume.iTunesDBURL))
        let chunk = try #require(db.playlistChunks.first { MHYP($0)?.id == playlist.id })
        let physical = chunk.children(tag: "mhip").compactMap(MHIP.init).map(\.trackID)
        #expect(physical == reversed)
    }

    // MARK: - Removing tracks from the device

    @MainActor
    @Test func removingTracksDeletesThemEverywhereIncludingNonMasterPlaylists() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDir = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let model = try await connectedModel(root: root)
        let trackIDs = try await seed(model, count: 3, sourceDirectory: sourceDir)
        await model.createPlaylist(title: "Holder", trackIDs: trackIDs)
        let playlist = try #require(model.editablePlaylists.first)

        model.selectedDeviceTrackIDs = [trackIDs[1]]
        await model.removeTracksFromDevice([trackIDs[1]])

        #expect(model.editState == .idle)
        #expect(model.deviceTracks.count == 2)
        // Gone from the playlist that held it, which kept its other tracks.
        let afterRemoval = try #require(model.editablePlaylists.first { $0.id == playlist.id })
        let expected = [trackIDs[0], trackIDs[2]]
        #expect(afterRemoval.trackIDsInOrder == expected)
        // And the selection is cleared, so the toolbar can't offer to delete
        // a track that no longer exists.
        #expect(model.selectedDeviceTrackIDs.isEmpty)
    }

    @MainActor
    @Test func removingAnUnknownTrackFailsLoudlyAndChangesNothing() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDir = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let model = try await connectedModel(root: root)
        let trackIDs = try await seed(model, count: 1, sourceDirectory: sourceDir)

        await model.removeTracksFromDevice([9999])

        guard case .failed(let message) = model.editState else {
            Issue.record("expected a failure, got \(model.editState)")
            return
        }
        #expect(message.contains("9999"))
        #expect(model.deviceTracks.count == trackIDs.count)

        model.dismissEditError()
        #expect(model.editState == .idle)
    }

    // MARK: - Track lookup

    @MainActor
    @Test func playlistEntriesResolveToTracksByID() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDir = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let model = try await connectedModel(root: root)
        let trackIDs = try await seed(model, count: 2, sourceDirectory: sourceDir)

        // Playlists store IDs, so every playlist row needs this to show
        // anything but a number.
        let track = try #require(model.deviceTrack(id: trackIDs[0]))
        #expect(track.uniqueID == trackIDs[0])
        #expect(model.deviceTrack(id: 4242) == nil)
    }

    /// Minimal 16-bit stereo PCM WAV, enough for the scanner and the engine.
    private func writeWAV(to url: URL, seconds: Double = 0.2, sampleRate: Int = 44_100) throws {
        let frames = Int(Double(sampleRate) * seconds)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let dataBytes = frames * 4
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(2)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 4)); append(UInt16(4)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
        for n in 0..<frames {
            let v = Int16(truncatingIfNeeded: Int(12000 * sin(2 * Double.pi * 440 * Double(n) / Double(sampleRate))))
            append(v); append(v)
        }
        try data.write(to: url)
    }
}
