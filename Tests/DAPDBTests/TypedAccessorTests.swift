import Foundation
import Testing
@testable import DAPDB

struct TypedAccessorTests {
    @Test func databaseHasZeroTracksAndSeveralPlaylists() throws {
        let data = try GoldenFixture.data()
        let db = try ITunesDatabase(parsing: data)

        #expect(db.tracks.isEmpty)
        #expect(db.playlists.isEmpty == false)
    }

    @Test func masterPlaylistTitleDecodesAsUTF16() throws {
        let data = try GoldenFixture.data()
        let db = try ITunesDatabase(parsing: data)

        let master = try #require(db.playlists.first { $0.isMaster })
        #expect(master.title == "johnreyes\u{2019}s iPod")
    }

    @Test func smartPlaylistsExposeOpaqueRuleData() throws {
        let data = try GoldenFixture.data()
        let db = try ITunesDatabase(parsing: data)

        // Two smart playlists (type=5 mhsd section) carry mhod type 50
        // (prefs) and 51 (rules) children that must never be reinterpreted.
        let smartPlaylists = db.playlistChunks
            .compactMap(MHYP.init)
            .filter { mhyp in mhyp.mhods.contains { $0.type == 50 } }
        #expect(smartPlaylists.count == 2)

        for mhyp in smartPlaylists {
            let prefs = try #require(mhyp.mhods.first { $0.type == 50 })
            let rules = try #require(mhyp.mhods.first { $0.type == 51 })
            #expect(prefs.kind == .smartPlaylistPrefs)
            #expect(rules.kind == .smartPlaylistRules)
            #expect(prefs.isStringType == false)
            #expect(rules.isStringType == false)
            #expect(prefs.stringValue == nil)
            #expect(rules.stringValue == nil)
            #expect(prefs.opaquePayload != nil)
            #expect(rules.opaquePayload != nil)
            // prefs mhod totalLen=96 (72-byte payload), rules mhod totalLen=408 (384-byte payload),
            // confirmed directly against the fixture's bytes.
            #expect(prefs.opaquePayload?.count == 72)
            #expect(rules.opaquePayload?.count == 384)
        }
    }

    @Test func mhitFileTypeMarkerRoundTripsAsRawUInt32() throws {
        let chunk = MHIT.make(MHIT.Fields(uniqueID: 1))
        let mhit = try #require(MHIT(chunk))
        #expect(mhit.filetypeMarker == 0)
    }

    @Test func mhodStringTypesCoverExpectedIDs() {
        #expect(MHOD.Kind(rawValue: 1) == .title)
        #expect(MHOD.Kind(rawValue: 2) == .location)
        #expect(MHOD.Kind(rawValue: 3) == .album)
        #expect(MHOD.Kind(rawValue: 4) == .artist)
        #expect(MHOD.Kind(rawValue: 5) == .genre)
        #expect(MHOD.Kind(rawValue: 6) == .filetype)
        #expect(MHOD.Kind(rawValue: 8) == .comment)
        #expect(MHOD.Kind(rawValue: 12) == .composer)
        #expect(MHOD.Kind(rawValue: 13) == .grouping)
        #expect(MHOD.Kind(rawValue: 50) == .smartPlaylistPrefs)
        #expect(MHOD.Kind(rawValue: 51) == .smartPlaylistRules)
    }

    // MARK: - Playlist sections

    @Test func playlistSectionsSeparateTheMirroredMasterPlaylistCopies() throws {
        let data = try GoldenFixture.data()
        let db = try ITunesDatabase(parsing: data)

        let sections = db.playlistSections
        // The fixture mirrors its master playlist across mhsd types 3 and 2,
        // and keeps its two smart playlists in mhsd type 5.
        let sectionTypes = sections.map(\.sectionType)
        let expectedTypes: [UInt32] = [3, 2, 5]
        #expect(sectionTypes == expectedTypes)

        // Flattening loses the distinction: the same persistent ID appears
        // in two sections, which is exactly what `playlists` can't express.
        let masterIDs = sections
            .flatMap(\.playlists)
            .filter(\.isMaster)
            .map(\.id)
        #expect(masterIDs.count == 2)
        #expect(masterIDs[0] == masterIDs[1])
    }

    @Test func playlistSectionsCoverExactlyTheSamePlaylistsAsTheFlatList() throws {
        let data = try GoldenFixture.data()
        let db = try ITunesDatabase(parsing: data)

        let flattened = db.playlistSections.flatMap(\.playlists)
        let flat = db.playlists
        #expect(flattened == flat)
    }

    @Test func playlistSectionsSkipSectionsHoldingNoPlaylists() throws {
        let data = try GoldenFixture.data()
        let db = try ITunesDatabase(parsing: data)

        // mhsd type 1 (tracks) and type 4 (albums) hold no mhyp at all.
        let types = Set(db.playlistSections.map(\.sectionType))
        #expect(types.contains(1) == false)
        #expect(types.contains(4) == false)
    }
}
