import Foundation
import Testing
@testable import DAPDB

struct PlaylistMutationTests {
    /// The master playlist's persistent ID in the golden fixture (confirmed
    /// via `xxd`/manual parsing: the mhyp at file offset 0x0328 has its 8-byte
    /// id field, at header offset 28, equal to this value).
    static let masterPlaylistID: UInt64 = 0x652463f2791cfe3d

    @Test func addAndRemovePlaylistEntryRecomputesCountsAndRoundTrips() throws {
        let data = try GoldenFixture.data()
        var db = try ITunesDatabase(parsing: data)

        let masterBefore = try #require(db.playlists.first { $0.id == Self.masterPlaylistID })
        #expect(masterBefore.trackIDsInOrder.isEmpty)

        let mhypBefore = try #require(db.playlistChunks.first { MHYP($0)?.id == Self.masterPlaylistID })
        let mhipCountFieldBefore = mhypBefore.headerBytes.leU32(at: 16)
        #expect(mhipCountFieldBefore == 0)

        let entry = MHIP.make(trackID: 4242, position: 0)
        try db.addPlaylistEntry(entry, toPlaylistID: Self.masterPlaylistID)

        let mhypAfter = try #require(db.playlistChunks.first { MHYP($0)?.id == Self.masterPlaylistID })
        #expect(mhypAfter.headerBytes.leU32(at: 16) == 1) // mhip count field
        #expect(Int(mhypAfter.headerBytes.leU32(at: 8) ?? 0) == mhypAfter.serializedByteCount) // totalLen

        let masterAfter = try #require(db.playlists.first { $0.id == Self.masterPlaylistID })
        #expect(masterAfter.trackIDsInOrder == [4242])

        // Ancestors up to the root must also reflect the new size.
        #expect(Int(db.root.headerBytes.leU32(at: 8) ?? 0) == db.root.serializedByteCount)

        // Must still be losslessly self-consistent after mutation.
        let reserialized = db.serialized()
        #expect(try ChunkTree.serialize(ChunkTree.parse(reserialized)) == reserialized)

        try db.removePlaylistEntry(trackID: 4242, fromPlaylistID: Self.masterPlaylistID)
        let masterFinal = try #require(db.playlists.first { $0.id == Self.masterPlaylistID })
        #expect(masterFinal.trackIDsInOrder.isEmpty)
    }

    @Test func removingATrackRemovesItsPlaylistEntriesEverywhere() throws {
        let data = try GoldenFixture.data()
        var db = try ITunesDatabase(parsing: data)

        let track = MHIT.make(MHIT.Fields(uniqueID: 7), strings: [.title: "Doomed"])
        try db.addTrack(track)

        // Reference track 7 from every *distinct* playlist ID in the tree.
        // (This fixture happens to mirror its master playlist's mhyp across
        // two mhsd sections under the same id — addPlaylistEntry targets a
        // playlist by id and only needs to hit one physical location for this
        // test's purposes; removeTrack's cleanup below is id-agnostic and
        // sweeps every mhip in every mhyp anywhere in the tree.)
        let distinctPlaylistIDs = Set(db.playlists.map(\.id))
        #expect(distinctPlaylistIDs.isEmpty == false)
        for id in distinctPlaylistIDs {
            try db.addPlaylistEntry(MHIP.make(trackID: 7, position: 0), toPlaylistID: id)
        }
        #expect(db.playlists.contains { $0.trackIDsInOrder.contains(7) })

        try db.removeTrack(uniqueID: 7)

        #expect(db.tracks.contains { $0.uniqueID == 7 } == false)
        #expect(db.playlists.allSatisfy { $0.trackIDsInOrder.contains(7) == false })

        let reserialized = db.serialized()
        #expect(try ChunkTree.serialize(ChunkTree.parse(reserialized)) == reserialized)
    }

    @Test func addingTrackToUnknownPlaylistThrows() throws {
        let data = try GoldenFixture.data()
        var db = try ITunesDatabase(parsing: data)
        #expect(throws: ChunkMutationError.playlistNotFound(0xDEAD_BEEF)) {
            try db.addPlaylistEntry(MHIP.make(trackID: 1, position: 0), toPlaylistID: 0xDEAD_BEEF)
        }
    }

    // MARK: - Reordering moves the entries themselves

    /// Reads a playlist's entries straight out of the chunk tree, in the
    /// order they physically appear, paired with the position each one
    /// claims. Deliberately bypasses `MHYP.trackIDsInOrder`: asserting a
    /// reorder through the same accessor the reorder updates is
    /// self-consistent no matter which encoding of order is wrong, which is
    /// how a reorder that the firmware ignored passed its tests and shipped.
    private func physicalEntries(_ db: ITunesDatabase, playlistID: UInt64) throws -> [(trackID: UInt32, position: UInt32?)] {
        let chunk = try #require(db.playlistChunks.first { MHYP($0)?.id == playlistID })
        return chunk.children(tag: "mhip").compactMap(MHIP.init).map { mhip in
            (mhip.trackID, mhip.mhods.first { $0.kind == .playlistPosition }?.playlistPosition)
        }
    }

    @Test func reorderingPhysicallyMovesEntriesBecauseTheFirmwareIgnoresPositions() throws {
        var db = try ITunesDatabase(parsing: try GoldenFixture.data())
        let id = try db.addPlaylist(title: "Order", inSectionType: 3)
        for (index, trackID) in [UInt32(10), 20, 30].enumerated() {
            try db.addPlaylistEntry(MHIP.make(trackID: trackID, position: UInt32(index)), toPlaylistID: id)
        }

        try db.reorderPlaylist(id: id, trackIDsInOrder: [30, 10, 20])

        let entries = try physicalEntries(db, playlistID: id)
        // The mhip children themselves must be in the new order — this is
        // what the device reads.
        let physicalOrder = entries.map(\.trackID)
        let expected: [UInt32] = [30, 10, 20]
        #expect(physicalOrder == expected)

        // And the positions must agree, so the two encodings never conflict.
        let positions = entries.map(\.position)
        let expectedPositions: [UInt32?] = [0, 1, 2]
        #expect(positions == expectedPositions)
    }

    @Test func reorderingSurvivesSerializationWithCorrectCountsAndLengths() throws {
        var db = try ITunesDatabase(parsing: try GoldenFixture.data())
        let id = try db.addPlaylist(title: "Order", inSectionType: 3)
        for (index, trackID) in [UInt32(1), 2, 3, 4].enumerated() {
            try db.addPlaylistEntry(MHIP.make(trackID: trackID, position: UInt32(index)), toPlaylistID: id)
        }
        try db.reorderPlaylist(id: id, trackIDsInOrder: [4, 3, 2, 1])

        let reparsed = try ITunesDatabase(parsing: db.serialized())
        let entries = try physicalEntries(reparsed, playlistID: id)
        let order = entries.map(\.trackID)
        let expected: [UInt32] = [4, 3, 2, 1]
        #expect(order == expected)

        let chunk = try #require(reparsed.playlistChunks.first { MHYP($0)?.id == id })
        #expect(chunk.headerBytes.leU32(at: 16) == 4) // mhip count
        #expect(Int(chunk.headerBytes.leU32(at: 8) ?? 0) == chunk.serializedByteCount) // totalLen
    }

    @Test func reorderingLeavesTheTitleMhodAheadOfTheEntries() throws {
        var db = try ITunesDatabase(parsing: try GoldenFixture.data())
        let id = try db.addPlaylist(title: "Keeps Its Name", inSectionType: 3)
        for (index, trackID) in [UInt32(7), 8].enumerated() {
            try db.addPlaylistEntry(MHIP.make(trackID: trackID, position: UInt32(index)), toPlaylistID: id)
        }
        try db.reorderPlaylist(id: id, trackIDsInOrder: [8, 7])

        let chunk = try #require(db.playlistChunks.first { MHYP($0)?.id == id })
        // Shuffling entries must not shuffle the mhods that precede them.
        let firstEntryIndex = try #require(chunk.children.firstIndex { $0.tag == "mhip" })
        let lastMhodIndex = try #require(chunk.children.lastIndex { $0.tag == "mhod" })
        #expect(lastMhodIndex < firstEntryIndex)
        #expect(MHYP(chunk)?.title == "Keeps Its Name")
    }

    @Test func removingATrackLeavesSurvivingEntriesContiguouslyNumbered() throws {
        var db = try ITunesDatabase(parsing: try GoldenFixture.data())
        let id = try db.addPlaylist(title: "Survivors", inSectionType: 3)
        for (index, trackID) in [UInt32(10), 20, 30, 40].enumerated() {
            try db.addPlaylistEntry(MHIP.make(trackID: trackID, position: UInt32(index)), toPlaylistID: id)
        }

        // Remove from the middle: the naive implementation leaves 0, 1, 3.
        try db.removeTrack(uniqueID: 30)

        let entries = try physicalEntries(db, playlistID: id)
        let order = entries.map(\.trackID)
        let expectedOrder: [UInt32] = [10, 20, 40]
        #expect(order == expectedOrder)

        let positions = entries.map(\.position)
        let expectedPositions: [UInt32?] = [0, 1, 2]
        #expect(positions == expectedPositions)
    }

    @Test func removingATrackRenumbersEveryPlaylistThatHeldItButLeavesOthersAlone() throws {
        var db = try ITunesDatabase(parsing: try GoldenFixture.data())
        let holder = try db.addPlaylist(title: "Holder", inSectionType: 3)
        let bystander = try db.addPlaylist(title: "Bystander", inSectionType: 3)

        for (index, trackID) in [UInt32(1), 2, 3].enumerated() {
            try db.addPlaylistEntry(MHIP.make(trackID: trackID, position: UInt32(index)), toPlaylistID: holder)
        }
        // Deliberately gapped, and untouched by the removal below — a
        // playlist that never held the track must not be rewritten.
        try db.addPlaylistEntry(MHIP.make(trackID: 7, position: 5), toPlaylistID: bystander)
        try db.addPlaylistEntry(MHIP.make(trackID: 8, position: 9), toPlaylistID: bystander)

        try db.removeTrack(uniqueID: 1)

        let holderPositions = try physicalEntries(db, playlistID: holder).map(\.position)
        let expectedHolder: [UInt32?] = [0, 1]
        #expect(holderPositions == expectedHolder)

        let bystanderPositions = try physicalEntries(db, playlistID: bystander).map(\.position)
        let expectedBystander: [UInt32?] = [5, 9]
        #expect(bystanderPositions == expectedBystander)
    }
}

/// The golden fixture mirrors its master playlist byte-for-byte across two
/// `mhsd` sections, which is precisely the shape that used to defeat
/// section-targeted insertion.
@Suite struct SectionTargetedInsertionTests {
    private func sectionTypesHolding(_ title: String, in db: ITunesDatabase) -> [UInt32] {
        db.playlistSections
            .filter { $0.playlists.contains { $0.title == title } }
            .map(\.sectionType)
    }

    @Test func mirroredSectionsAreActuallyIndistinguishableByValue() throws {
        // Guards the premise of the test below: if the fixture ever stops
        // holding two byte-identical playlist lists, the regression this
        // suite covers can no longer occur and the test is misleading.
        let db = try ITunesDatabase(parsing: try GoldenFixture.data())
        let lists = db.root.children(tag: "mhsd")
            .compactMap { $0.firstDescendant(where: { $0.tag == "mhlp" }) }
        #expect(lists.count >= 2)
        #expect(lists[0] == lists[1], "expected two mirrored, byte-identical mhlp chunks")
    }

    @Test func playlistLandsInTheRequestedSectionNotTheFirstMatchingMirror() throws {
        var db = try ITunesDatabase(parsing: try GoldenFixture.data())

        // Section 2 is the *second* of the two mirrors in file order. An
        // equality-based search finds the section-3 copy first and appends
        // there instead, which is the bug this covers.
        try db.addPlaylist(title: "Into Two", inSectionType: 2)

        #expect(sectionTypesHolding("Into Two", in: db) == [2])
    }

    @Test func eachCandidateSectionCanBeTargetedIndependently() throws {
        var db = try ITunesDatabase(parsing: try GoldenFixture.data())
        let available = Set(db.playlistSections.map(\.sectionType))

        for sectionType in available.sorted() {
            let title = "Target \(sectionType)"
            try db.addPlaylist(title: title, inSectionType: sectionType)
            #expect(sectionTypesHolding(title, in: db) == [sectionType])
        }

        // And it must survive a serialize/parse round trip, so the counts
        // and lengths written up to the root are right.
        let reparsed = try ITunesDatabase(parsing: db.serialized())
        for sectionType in available.sorted() {
            #expect(sectionTypesHolding("Target \(sectionType)", in: reparsed) == [sectionType])
        }
    }

    @Test func targetingASectionWithNoPlaylistListStillThrows() throws {
        var db = try ITunesDatabase(parsing: try GoldenFixture.data())
        #expect(throws: (any Error).self) {
            try db.addPlaylist(title: "Nowhere", inSectionType: 99)
        }
    }
}
