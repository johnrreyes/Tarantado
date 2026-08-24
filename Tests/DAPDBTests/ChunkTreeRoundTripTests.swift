import Foundation
import Testing
@testable import DAPDB

struct ChunkTreeRoundTripTests {
    @Test func goldenDatabaseRoundTripsByteForByte() throws {
        let data = try GoldenFixture.data()
        #expect(data.count == 8206)

        let tree = try ChunkTree.parse(data)
        let reserialized = ChunkTree.serialize(tree)
        #expect(reserialized == data)
    }

    @Test func goldenDatabaseStructureMatchesKnownOffsets() throws {
        let data = try GoldenFixture.data()
        let root = try ChunkTree.parse(data)

        #expect(root.tag == "mhbd")
        #expect(root.headerLen == 244)
        #expect(root.headerBytes.leU32(at: 8) == 8206) // totalLen == whole file

        let mhsds = root.children(tag: "mhsd")
        #expect(mhsds.count == 5) // matches mhbd's own child count field at offset 20

        // mhsd type=4 -> mhla (album list), empty.
        let albumSection = try #require(mhsds.first { $0.headerBytes.leU32(at: 12) == 4 })
        let mhla = try #require(albumSection.firstChild(tag: "mhla"))
        #expect(mhla.headerLen == 92)
        #expect(mhla.headerBytes.leU32(at: 8) == 0) // count of mhia children
        #expect(mhla.children.isEmpty)

        // mhsd type=1 -> mhlt (track list), zero tracks.
        let trackSection = try #require(mhsds.first { $0.headerBytes.leU32(at: 12) == 1 })
        let mhlt = try #require(trackSection.firstChild(tag: "mhlt"))
        #expect(mhlt.headerLen == 92)
        #expect(mhlt.headerBytes.leU32(at: 8) == 0) // track count
        #expect(mhlt.children.isEmpty)

        // Every remaining mhsd is a playlist section (mhlp -> one or more mhyp).
        // This fixture happens to carry 3 such sections (types 2, 3, 5) — the
        // master playlist appears to be mirrored across two of them.
        let playlistSections = mhsds.filter { $0.headerBytes.leU32(at: 12) != 4 && $0.headerBytes.leU32(at: 12) != 1 }
        #expect(playlistSections.count == 3)
        let allPlaylists = playlistSections.flatMap { section in
            section.children(tag: "mhlp").flatMap { $0.children(tag: "mhyp") }
        }
        #expect(allPlaylists.count >= 3) // master playlist + at least 2 smart playlists

        // Every mhyp's totalLen should exactly cover its own headerBytes + children + trailing.
        for playlist in allPlaylists {
            #expect(Int(playlist.headerBytes.leU32(at: 8) ?? 0) == playlist.serializedByteCount)
        }
    }

    @Test func parsingRejectsTruncatedBuffer() throws {
        let data = try GoldenFixture.data()
        let truncated = data.prefix(100)
        #expect(throws: (any Error).self) {
            _ = try ChunkTree.parse(Data(truncated))
        }
    }
}
