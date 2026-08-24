import Foundation
import Testing
@testable import DAPDB

/// Album art arrived with the 5G iPod Video, and with it the `mhli` image
/// list — a list header whose offset 8 is a child *count*, exactly like
/// `mhlt`/`mhlp`/`mhla`. Reading it as a sized container made every 5G
/// database unparseable: the image count (23, on the device that reported
/// this) was compared against the 92-byte header as if it were a length, and
/// connecting failed before a single track was read.
///
/// The golden fixture is from a mini 2G, which predates album art, so no real
/// bytes here can cover this. These chunks are assembled by hand to the shape
/// the reporter's hex window showed:
///
///     6d 68 6c 69  5c 00 00 00  17 00 00 00  00 00 00 00
///     m  h  l  i   headerLen 92  count 23     (padding)
struct ImageListParsingTests {

    // MARK: - Byte builders

    private static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xff) }
    }

    /// A family-A chunk: offset 8 holds the total byte length of header +
    /// children, and the header is zero-padded out to `headerLen`.
    private static func sized(_ tag: String, headerLen: Int, children: [[UInt8]] = []) -> [UInt8] {
        let body = children.flatMap { $0 }
        var header = Array(tag.utf8) + le32(UInt32(headerLen)) + le32(UInt32(headerLen + body.count))
        header += [UInt8](repeating: 0, count: headerLen - header.count)
        return header + body
    }

    /// A family-B chunk: offset 8 holds the number of children, and the
    /// chunk's extent is however many bytes those children happen to occupy.
    private static func counted(_ tag: String, headerLen: Int, children: [[UInt8]] = []) -> [UInt8] {
        var header = Array(tag.utf8) + le32(UInt32(headerLen)) + le32(UInt32(children.count))
        header += [UInt8](repeating: 0, count: headerLen - header.count)
        return header + children.flatMap { $0 }
    }

    /// One image entry. Real ones carry mhod/mhni children; the parser only
    /// cares that it is a well-formed sized container.
    private static func mhii() -> [UInt8] { sized("mhii", headerLen: 152) }

    /// A database shaped like the reporter's: a track section, then an
    /// artwork section holding an `mhli` with `imageCount` entries.
    private static func databaseWithArtwork(imageCount: Int) -> Data {
        let images = (0..<imageCount).map { _ in mhii() }
        let artworkSection = sized("mhsd", headerLen: 96, children: [
            counted("mhli", headerLen: 92, children: images)
        ])
        let trackSection = sized("mhsd", headerLen: 96, children: [
            counted("mhlt", headerLen: 92, children: [])
        ])
        return Data(sized("mhbd", headerLen: 104, children: [trackSection, artworkSection]))
    }

    // MARK: - Tests

    @Test("mhli is a counted list, not a sized container")
    func imageListIsACountedList() {
        #expect(ChunkTag.family(for: "mhli") == .countedList)
        #expect(ChunkTag.family(for: "mhlf") == .countedList)
        // The individual entry is still a sized container, as are its siblings.
        #expect(ChunkTag.family(for: "mhii") == .sizedContainer)
        #expect(ChunkTag.family(for: "mhia") == .sizedContainer)
    }

    @Test("a database carrying album art parses instead of failing on mhli")
    func artworkDatabaseParses() throws {
        let data = Self.databaseWithArtwork(imageCount: 23)
        let root = try ChunkTree.parse(data)

        let imageList = try #require(root.firstDescendant { $0.tag == "mhli" })
        #expect(imageList.headerLen == 92)
        #expect(imageList.children.count == 23)
        #expect(imageList.children.allSatisfy { $0.tag == "mhii" })
    }

    @Test("an artwork database round-trips byte-for-byte")
    func artworkDatabaseRoundTrips() throws {
        let data = Self.databaseWithArtwork(imageCount: 23)
        let root = try ChunkTree.parse(data)
        #expect(ChunkTree.serialize(root) == data)
    }

    @Test("the reporter's exact failure no longer happens")
    func theReportedFailureIsGone() {
        // Before the fix this threw with "totalLen 23 < headerLen 92".
        #expect(throws: Never.self) {
            _ = try ChunkTree.parse(Self.databaseWithArtwork(imageCount: 23))
        }
    }

    @Test("an empty image list is still a list, not a zero-length chunk")
    func emptyImageListParses() throws {
        let root = try ChunkTree.parse(Self.databaseWithArtwork(imageCount: 0))
        let imageList = try #require(root.firstDescendant { $0.tag == "mhli" })
        #expect(imageList.children.isEmpty)
        // A sized container reading count 0 as totalLen would have thrown;
        // a counted list ends immediately after its own header.
        #expect(imageList.serializedByteCount == 92)
    }

    @Test("an unknown mhl? tag is guessed as a list rather than failing")
    func unknownListHeaderIsGuessedAsAList() throws {
        // Whatever the next unreadable-device report turns out to be, a tag
        // following the "mhl" + one letter naming convention should parse.
        #expect(ChunkTag.family(for: "mhlq") == .countedList)
        let data = Data(Self.sized("mhbd", headerLen: 104, children: [
            Self.counted("mhlq", headerLen: 92, children: [Self.mhii(), Self.mhii()])
        ]))
        let root = try ChunkTree.parse(data)
        let list = try #require(root.firstChild(tag: "mhlq"))
        #expect(list.children.count == 2)
        #expect(ChunkTree.serialize(root) == data)
    }

    @Test("recomputing an image list's header rewrites its count, not a length")
    func recomputingAnImageListWritesTheCount() throws {
        var imageList = try #require(
            try ChunkTree.parse(Self.databaseWithArtwork(imageCount: 23))
                .firstDescendant { $0.tag == "mhli" }
        )
        imageList.children.removeLast()
        imageList.recomputeDerivedFields()
        #expect(imageList.headerBytes.leU32(at: 8) == 22)
    }
}
