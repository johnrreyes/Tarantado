import Foundation
import Testing
@testable import DAPDB

struct MHITSyntheticTests {
    @Test func syntheticTrackRoundTripsEveryField() throws {
        var fields = MHIT.Fields(uniqueID: 42)
        fields.visible = false
        fields.filetypeMarker = 0x4D503320 // "MP3 "
        fields.size = 5_242_880
        fields.length = 213_000
        fields.trackNumber = 3
        fields.totalTracks = 12
        fields.year = 2004
        fields.bitrate = 192
        fields.sampleRate = 44_100
        fields.playCount = 7
        fields.rating = 80
        fields.dateAdded = Date(timeIntervalSince1970: 1_700_000_000)
        fields.lastPlayed = Date(timeIntervalSince1970: 1_720_000_000)
        fields.discNumber = 1
        fields.totalDiscs = 2
        fields.dbid = 0x0123_4567_89AB_CDEF
        fields.mediaType = 1 // ITDB_MEDIATYPE_AUDIO

        let strings: [MHOD.Kind: String] = [
            .title: "Test Track",
            .artist: "Test Artist",
            .album: "Test Album",
            .genre: "Rock",
            .comment: "A comment with unicode: caf\u{00e9} \u{1F3B5}",
        ]

        let mhitChunk = MHIT.make(fields, strings: strings)

        // Round-trip through serialize -> parse.
        let serialized = ChunkTree.serialize(mhitChunk)
        let reparsedRoot = try ChunkTree.parse(serialized)
        #expect(reparsedRoot.tag == "mhit")

        let mhit = try #require(MHIT(reparsedRoot))

        #expect(mhit.uniqueID == 42)
        #expect(mhit.visible == false)
        #expect(mhit.filetypeMarker == 0x4D50_3320)
        #expect(mhit.size == 5_242_880)
        #expect(mhit.length == 213_000)
        #expect(mhit.trackNumber == 3)
        #expect(mhit.totalTracks == 12)
        #expect(mhit.year == 2004)
        #expect(mhit.bitrate == 192)
        #expect(mhit.sampleRate == 44_100)
        #expect(mhit.playCount == 7)
        #expect(mhit.rating == 80)
        #expect(mhit.dateAdded == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(mhit.lastPlayed == Date(timeIntervalSince1970: 1_720_000_000))
        #expect(mhit.discNumber == 1)
        #expect(mhit.totalDiscs == 2)
        #expect(mhit.dbid == 0x0123_4567_89AB_CDEF)
        #expect(mhit.mediaType == 1)

        #expect(mhit.title == "Test Track")
        #expect(mhit.artist == "Test Artist")
        #expect(mhit.album == "Test Album")
        #expect(mhit.genre == "Rock")
        #expect(mhit.comment == "A comment with unicode: caf\u{00e9} \u{1F3B5}")

        // Bytes must be self-consistent, not just field-consistent.
        #expect(reparsedRoot.headerBytes.leU32(at: 8) == UInt32(reparsedRoot.serializedByteCount))
        #expect(reparsedRoot.headerBytes.leU32(at: 12) == UInt32(reparsedRoot.children.count))
    }

    @Test func mutatingATreeRecomputesTotalLenAndCountsAndStillParses() throws {
        let data = try GoldenFixture.data()
        var db = try ITunesDatabase(parsing: data)

        let originalRoot = db.root
        let originalMhlt = try #require(originalRoot.firstDescendant { $0.tag == "mhlt" })
        #expect(originalMhlt.headerBytes.leU32(at: 8) == 0)

        let newTrack = MHIT.make(MHIT.Fields(uniqueID: 999), strings: [.title: "Appended"])
        try db.addTrack(newTrack)

        // mhlt count updated.
        let newMhlt = try #require(db.root.firstDescendant { $0.tag == "mhlt" })
        #expect(newMhlt.headerBytes.leU32(at: 8) == 1)
        #expect(newMhlt.children.count == 1)

        // Every ancestor's totalLen must reflect the new size, all the way to the root.
        let mhsdContainingTrackList = try #require(db.root.children.first { $0.children(tag: "mhlt").isEmpty == false })
        #expect(Int(mhsdContainingTrackList.headerBytes.leU32(at: 8) ?? 0) == mhsdContainingTrackList.serializedByteCount)
        #expect(Int(db.root.headerBytes.leU32(at: 8) ?? 0) == db.root.serializedByteCount)
        #expect(db.root.headerBytes.leU32(at: 8) != originalRoot.headerBytes.leU32(at: 8))

        // The mutated tree must still parse identically to how it serializes (self-consistency,
        // not just "doesn't crash").
        let reserialized = db.serialized()
        let reparsed = try ChunkTree.parse(reserialized)
        #expect(ChunkTree.serialize(reparsed) == reserialized)
        #expect(db.tracks.count == 1)
        #expect(db.tracks[0].uniqueID == 999)
        #expect(db.tracks[0].title == "Appended")

        // Remove it again and confirm counts go back down.
        try db.removeTrack(uniqueID: 999)
        #expect(db.tracks.isEmpty)
        let finalMhlt = try #require(db.root.firstDescendant { $0.tag == "mhlt" })
        #expect(finalMhlt.headerBytes.leU32(at: 8) == 0)
    }
}
