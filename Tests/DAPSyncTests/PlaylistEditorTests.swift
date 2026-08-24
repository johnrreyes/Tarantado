import Foundation
import Testing
import DAPDB
import DAPDevice
@testable import DAPSync

@Suite struct PlaylistEditorTests {
    /// Master playlist's persistent ID in the golden fixture — same constant
    /// `SyncEngineTests` uses.
    private static let masterPlaylistID: UInt64 = 0x652463f2791cfe3d

    // MARK: - Fixtures

    private func makeSourceDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func wavSourceTrack(url: URL, size: Int64, title: String, artist: String) -> SourceTrack {
        SourceTrack(
            fileURL: url,
            fileSize: size,
            title: title,
            artist: artist,
            album: "Test Album",
            durationMS: 200,
            compatibility: .passThrough(SourceAudioFormat(kind: .wav, filetypeMarker: 0x2056_4157, filetypeString: "WAV audio file"))
        )
    }

    /// Puts `count` real (synthetic WAV) tracks onto a synthetic iPod using
    /// the ordinary add path, so playlist tests operate on a database that
    /// actually has tracks in it — the golden fixture ships with none.
    /// Returns the volume and the unique IDs allocated, in order.
    private func seededVolume(root: URL, sourceDirectory: URL, count: Int) async throws -> (volume: DAPVolume, trackIDs: [UInt32]) {
        let volume = try DAPVolume.validate(at: root)

        var sources: [SourceTrack] = []
        for index in 0..<count {
            let url = sourceDirectory.appendingPathComponent("track\(index).wav")
            try SyntheticAudio.makeWAV(at: url, durationSeconds: 0.2)
            let size = Int64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
            sources.append(wavSourceTrack(url: url, size: size, title: "Track \(index)", artist: "Artist \(index)"))
        }

        let plan = SyncPlan.compute(deviceTracks: [], sourceTracks: sources)
        let report = try await SyncEngine.apply(plan: plan, to: volume)
        #expect(report.failures.isEmpty)
        #expect(report.added.count == count)
        return (volume, report.added.map(\.uniqueID))
    }

    private func playlist(named title: String, on volume: DAPVolume) throws -> Playlist? {
        try PlaylistEditor(volume: volume).database().playlists.first { $0.title == title }
    }

    // MARK: - Creating

    @Test func createsAPlaylistWithTracksInTheGivenOrder() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let (volume, trackIDs) = try await seededVolume(root: root, sourceDirectory: sourceDirectory, count: 3)
        let editor = PlaylistEditor(volume: volume)

        let wanted = [trackIDs[2], trackIDs[0], trackIDs[1]]
        let (id, backup) = try editor.create(title: "Road Trip", trackIDs: wanted)
        #expect(backup != nil)

        // Re-read from disk: the point is that it was written, not just mutated in memory.
        let reloaded = try #require(try playlist(named: "Road Trip", on: volume))
        #expect(reloaded.id == id)
        #expect(reloaded.isMaster == false)
        #expect(reloaded.isSmart == false)
        let actualOrder = reloaded.trackIDsInOrder
        #expect(actualOrder == wanted)
    }

    @Test func createdPlaylistSurvivesAByteLevelReparse() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let (volume, trackIDs) = try await seededVolume(root: root, sourceDirectory: sourceDirectory, count: 2)
        try PlaylistEditor(volume: volume).create(title: "Mix", trackIDs: trackIDs)

        // Serializing what we just parsed must reproduce the file byte for
        // byte — the same round-trip property the golden test asserts, but
        // for a database this library wrote rather than one iTunes wrote.
        let onDisk = try Data(contentsOf: volume.iTunesDBURL)
        let reserialized = try ITunesDatabase(parsing: onDisk).serialized()
        #expect(reserialized == onDisk)
    }

    @Test func refusesToCreateAPlaylistReferencingATrackThatIsNotOnTheDevice() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let (volume, trackIDs) = try await seededVolume(root: root, sourceDirectory: sourceDirectory, count: 1)
        let editor = PlaylistEditor(volume: volume)
        let before = try Data(contentsOf: volume.iTunesDBURL)

        #expect(throws: PlaylistEditorError.unknownTrackIDs([9999])) {
            try editor.create(title: "Bogus", trackIDs: [trackIDs[0], 9999])
        }

        // A rejected edit must leave the on-device database exactly as it was.
        let after = try Data(contentsOf: volume.iTunesDBURL)
        #expect(after == before)
    }

    // MARK: - Refusals

    @Test func refusesToWriteToADeviceRequiringADatabaseSignature() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }

        let baseVolume = try DAPVolume.validate(at: root)
        let riskyModel = DeviceModel(
            displayName: "iPod classic (6th generation, 80GB)",
            generation: "classic 6G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .hash58,
            supportsArtwork: true,
            musicFolderCount: 50
        )
        let riskyVolume = DAPVolume(rootURL: baseVolume.rootURL, sysInfo: baseVolume.sysInfo, model: riskyModel)
        let before = try Data(contentsOf: riskyVolume.iTunesDBURL)

        #expect(throws: PlaylistEditorError.databaseSignatureRequired(.hash58)) {
            try PlaylistEditor(volume: riskyVolume).create(title: "Nope")
        }
        let after = try Data(contentsOf: riskyVolume.iTunesDBURL)
        #expect(after == before)
    }

    @Test func refusesToRenameOrDeleteTheMasterPlaylist() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)
        let editor = PlaylistEditor(volume: volume)
        let masterID = Self.masterPlaylistID

        #expect(throws: ITunesDatabase.PlaylistEditError.cannotModifyMasterPlaylist(masterID)) {
            try editor.rename(id: masterID, to: "Everything")
        }
        #expect(throws: ITunesDatabase.PlaylistEditError.cannotModifyMasterPlaylist(masterID)) {
            try editor.delete(id: masterID)
        }
        #expect(throws: ITunesDatabase.PlaylistEditError.cannotModifyMasterPlaylist(masterID)) {
            try editor.addTracks([1], toPlaylistID: masterID)
        }

        // The master playlist is still there, still master, still named what it was.
        let master = try #require(editor.database().playlists.first { $0.id == masterID })
        #expect(master.isMaster)
    }

    // MARK: - Resolving

    @Test func resolvesAPlaylistByPersistentIDOrByExactTitle() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let (volume, _) = try await seededVolume(root: root, sourceDirectory: sourceDirectory, count: 1)
        let editor = PlaylistEditor(volume: volume)
        let (id, _) = try editor.create(title: "Evening")

        let db = try editor.database()
        #expect(try editor.resolve(String(id), in: db).id == id)
        #expect(try editor.resolve("Evening", in: db).id == id)
        #expect(throws: PlaylistEditorError.playlistNotFound("Morning")) {
            try editor.resolve("Morning", in: db)
        }
    }

    @Test func refusesToResolveATitleSharedByTwoPlaylists() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)
        let editor = PlaylistEditor(volume: volume)

        let (first, _) = try editor.create(title: "Dupe")
        let (second, _) = try editor.create(title: "Dupe")
        let db = try editor.database()

        #expect(throws: PlaylistEditorError.self) {
            try editor.resolve("Dupe", in: db)
        }
        // Both are addressable by ID even though the title is ambiguous.
        let firstResolved = try editor.resolve(String(first), in: db).id
        let secondResolved = try editor.resolve(String(second), in: db).id
        #expect(firstResolved == first)
        #expect(secondResolved == second)
    }

    @Test func resolvesAPlaylistThatTheFirmwareHasMirroredAcrossSections() throws {
        // The Apple firmware rewrites the database on eject and files each
        // playlist into two mhsd sections under one persistent ID. Observed
        // on the reference iPod 4G, where every playlist then failed to
        // resolve by name with "ambiguousPlaylistName(matchingIDs: [X, X])".
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)
        let editor = PlaylistEditor(volume: volume)

        let (id, _) = try editor.create(title: "Mirrored", sectionType: 3)

        var db = try editor.database()
        let chunk = try #require(db.playlistChunks.first { MHYP($0)?.id == id })
        db.root = try ChunkMutation.addingPlaylist(chunk, toSectionType: 2, in: db.root)

        // Same playlist, same ID, present in two sections.
        let rows = db.playlists.filter { $0.title == "Mirrored" }
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)) == [id])

        #expect(try editor.resolve("Mirrored", in: db).id == id)
    }

    // MARK: - Membership

    @Test func addingTracksAppendsAndSkipsOnesAlreadyInThePlaylist() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let (volume, trackIDs) = try await seededVolume(root: root, sourceDirectory: sourceDirectory, count: 3)
        let editor = PlaylistEditor(volume: volume)
        let (id, _) = try editor.create(title: "Growing", trackIDs: [trackIDs[0]])

        try editor.addTracks([trackIDs[1], trackIDs[0], trackIDs[2]], toPlaylistID: id)

        let reloaded = try #require(editor.database().playlists.first { $0.id == id })
        // trackIDs[0] was already there, so it keeps its original position
        // and is not listed twice.
        let expected = [trackIDs[0], trackIDs[1], trackIDs[2]]
        let actual = reloaded.trackIDsInOrder
        #expect(actual == expected)
    }

    @Test func removingTracksFromAPlaylistKeepsTheTracksAndTheirFilesOnTheDevice() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let (volume, trackIDs) = try await seededVolume(root: root, sourceDirectory: sourceDirectory, count: 3)
        let filesBefore = SyntheticDAP.musicFileListing(volume)
        let editor = PlaylistEditor(volume: volume)
        let (id, _) = try editor.create(title: "Shrinking", trackIDs: trackIDs)

        try editor.removeTracks([trackIDs[1]], fromPlaylistID: id)

        let db = try editor.database()
        let reloaded = try #require(db.playlists.first { $0.id == id })
        let remaining = reloaded.trackIDsInOrder
        let expectedRemaining = [trackIDs[0], trackIDs[2]]
        #expect(remaining == expectedRemaining)

        // The track itself is untouched: still in the database, still in the
        // master playlist, and its audio file is still on disk.
        let allTrackIDs = Set(db.tracks.map(\.uniqueID))
        let seededIDs = Set(trackIDs)
        #expect(allTrackIDs == seededIDs)
        let masterPlaylist = db.playlists.first { $0.isMaster }
        let master = try #require(masterPlaylist)
        let masterIDs = Set(master.trackIDsInOrder)
        #expect(masterIDs == seededIDs)
        let filesAfter = SyntheticDAP.musicFileListing(volume)
        #expect(filesAfter == filesBefore)
    }

    @Test func removingAMiddleTrackRenumbersTheRemainingPositionsContiguously() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let (volume, trackIDs) = try await seededVolume(root: root, sourceDirectory: sourceDirectory, count: 3)
        let editor = PlaylistEditor(volume: volume)
        let (id, _) = try editor.create(title: "Gaps", trackIDs: trackIDs)
        try editor.removeTracks([trackIDs[0]], fromPlaylistID: id)

        let chunk = try #require(editor.database().playlistChunks.first { MHYP($0)?.id == id })
        let positions = MHYP(chunk)!.mhips.compactMap { mhip in
            mhip.mhods.first { $0.kind == .playlistPosition }?.playlistPosition
        }
        let sortedPositions = positions.sorted()
        let contiguous: [UInt32] = [0, 1]
        #expect(sortedPositions == contiguous)
    }

    // MARK: - Rename / delete

    @Test func renamingAndDeletingARegularPlaylistRoundTripsThroughTheDevice() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let (volume, trackIDs) = try await seededVolume(root: root, sourceDirectory: sourceDirectory, count: 2)
        let editor = PlaylistEditor(volume: volume)
        let playlistsBefore = try editor.database().playlists.count

        let (id, _) = try editor.create(title: "Old Name", trackIDs: trackIDs)
        try editor.rename(id: id, to: "New Name")
        let renamed = try #require(editor.database().playlists.first { $0.id == id })
        #expect(renamed.title == "New Name")
        let orderAfterRename = renamed.trackIDsInOrder
        #expect(orderAfterRename == trackIDs)

        try editor.delete(id: id)
        let after = try editor.database()
        #expect(after.playlists.contains { $0.id == id } == false)
        #expect(after.playlists.count == playlistsBefore)
        // Deleting a playlist must not delete its tracks.
        #expect(after.tracks.count == trackIDs.count)
    }

    // MARK: - Reordering

    @Test func reorderingRewritesPlaylistOrderButRejectsANonPermutation() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let (volume, trackIDs) = try await seededVolume(root: root, sourceDirectory: sourceDirectory, count: 3)
        let editor = PlaylistEditor(volume: volume)
        let (id, _) = try editor.create(title: "Ordered", trackIDs: trackIDs)

        let reversed = Array(trackIDs.reversed())
        try editor.reorder(id: id, trackIDsInOrder: reversed)
        let reloaded = try #require(editor.database().playlists.first { $0.id == id })
        let actual = reloaded.trackIDsInOrder
        #expect(actual == reversed)

        #expect(throws: ITunesDatabase.PlaylistEditError.reorderTrackSetMismatch(id)) {
            try editor.reorder(id: id, trackIDsInOrder: [trackIDs[0]])
        }
    }

    // MARK: - Section targeting

    @Test func creatingWithAnExplicitSectionTypeFilesThePlaylistThere() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let (volume, trackIDs) = try await seededVolume(root: root, sourceDirectory: sourceDirectory, count: 2)
        let editor = PlaylistEditor(volume: volume)

        let (inTwo, _) = try editor.create(title: "Into 2", trackIDs: trackIDs, sectionType: 2)
        let (inThree, _) = try editor.create(title: "Into 3", trackIDs: trackIDs, sectionType: 3)

        let sections = try editor.database().playlistSections
        let two = try #require(sections.first { $0.sectionType == 2 })
        let three = try #require(sections.first { $0.sectionType == 3 })
        #expect(two.playlists.contains { $0.id == inTwo })
        #expect(three.playlists.contains { $0.id == inThree })
        // Each landed in exactly one section, not both.
        #expect(two.playlists.contains { $0.id == inThree } == false)
        #expect(three.playlists.contains { $0.id == inTwo } == false)
    }

    @Test func creatingInASectionThatHoldsNoPlaylistListIsRefused() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)
        let editor = PlaylistEditor(volume: volume)
        let before = try Data(contentsOf: volume.iTunesDBURL)

        // mhsd type 1 is the track list; it has no mhlp to append to.
        #expect(throws: ChunkMutationError.noPlaylistListInSection(1)) {
            try editor.create(title: "Nowhere", sectionType: 1)
        }
        let after = try Data(contentsOf: volume.iTunesDBURL)
        #expect(after == before)
    }

    @Test func aSectionTargetedPlaylistSurvivesAByteLevelReparse() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let (volume, trackIDs) = try await seededVolume(root: root, sourceDirectory: sourceDirectory, count: 2)
        try PlaylistEditor(volume: volume).create(title: "Probe", trackIDs: trackIDs, sectionType: 2)

        let onDisk = try Data(contentsOf: volume.iTunesDBURL)
        let reserialized = try ITunesDatabase(parsing: onDisk).serialized()
        #expect(reserialized == onDisk)
    }

    // MARK: - Verified section from the device model

    @Test func createWithNoExplicitSectionUsesTheModelsVerifiedSection() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let sourceDirectory = try makeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let (volume, trackIDs) = try await seededVolume(root: root, sourceDirectory: sourceDirectory, count: 2)
        // The synthetic volume carries the reference mini 2G SysInfo, whose
        // verified playlist section is 3.
        #expect(volume.model.playlistSectionType == 3)

        let (id, _) = try PlaylistEditor(volume: volume).create(title: "Default", trackIDs: trackIDs)

        let sections = try PlaylistEditor(volume: volume).database().playlistSections
        let three = try #require(sections.first { $0.sectionType == 3 })
        #expect(three.playlists.contains { $0.id == id })
        // Not into section 5, which is where the "most children" heuristic
        // would have put it once two smart playlists live there.
        let five = try #require(sections.first { $0.sectionType == 5 })
        #expect(five.playlists.contains { $0.id == id } == false)
    }

    @Test func createRefusesWhenTheModelsPlaylistSectionIsUnverified() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }

        let baseVolume = try DAPVolume.validate(at: root)
        let unverifiedModel = DeviceModel(
            displayName: "iPod nano (2nd generation)",
            generation: "nano 2G",
            family: .nano,
            requiresDatabaseSignature: .none,
            supportsArtwork: true,
            musicFolderCount: 50,
            playlistSectionType: nil
        )
        let volume = DAPVolume(rootURL: baseVolume.rootURL, sysInfo: baseVolume.sysInfo, model: unverifiedModel)
        let before = try Data(contentsOf: volume.iTunesDBURL)

        #expect(throws: PlaylistEditorError.playlistSectionUnknown(modelName: "iPod nano (2nd generation)")) {
            try PlaylistEditor(volume: volume).create(title: "Nope")
        }
        let after = try Data(contentsOf: volume.iTunesDBURL)
        #expect(after == before)

        // An explicit section is still allowed — that's how a new model's
        // section gets determined in the first place.
        let (id, _) = try PlaylistEditor(volume: volume).create(title: "Probe", sectionType: 3)
        let sections = try PlaylistEditor(volume: volume).database().playlistSections
        let three = try #require(sections.first { $0.sectionType == 3 })
        #expect(three.playlists.contains { $0.id == id })
    }
}
