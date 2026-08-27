import Foundation

/// Typed view over an "mhod" chunk as it appears inside **ArtworkDB**
/// (`iPod_Control/Artwork/ArtworkDB`) — a different byte shape from
/// `MHOD`, which covers iTunesDB's "mhod". The two share a tag but not a
/// header layout, so they are deliberately separate types rather than one
/// reused across both databases.
///
/// Field offsets cross-checked against libgpod's `_ArtworkDB_MhodHeader` /
/// `_ArtworkDB_MhodHeaderString` in `db-itunes-parser.h`, and against
/// `write_mhod`/`write_mhod_type_3` in `db-artwork-writer.c`, which contain
/// the explicit comment this mirrors: "iTunes only puts the length of
/// MhodHeader in header_len" — i.e. `headerLen` is **always 24** here, even
/// for the string variant whose real fixed portion is 36 bytes. The extra 12
/// bytes land in `trailingBytes`, ahead of the string payload, exactly the
/// way this library already represents "declared header shorter than the
/// data that follows" elsewhere. Independently cross-checked against
/// iOpenPod's `artworkdb_shared/mhod.py`, which arrives at the identical
/// 24-byte header / trailing-prefix split from its own reverse-engineering.
///
/// ```
/// 0  tag "mhod"
/// 4  headerLen (u32) = 24
/// 8  totalLen  (u32)
/// 12 type      (i16) — an `ArtworkMHOD.Kind` raw value
/// 14 unknown   (i16)
/// 16 unknown   (u32)
/// 20 unknown   (u32)
/// ```
/// For the **container** kind (`.thumbnailImage`, `.fullResImage`), the sole
/// child is one nested chunk (an `mhni` for thumbnails) and `trailingBytes`
/// is empty.
///
/// For the **string** kinds (`.albumName`, `.fileName`), there is no child
/// chunk; `trailingBytes` holds:
/// ```
/// 0  string byte length (u32)
/// 4  encoding (u8) — 1 = UTF-8, 2 = UTF-16LE
/// 5  3 unknown bytes (zero)
/// 8  4 unknown bytes (zero)
/// 12 string bytes, `byteLength` bytes
///    + zero padding out to a multiple of 4
/// ```
/// `.fileName` (an `.ithmb` path such as `:F1029_1.ithmb`) is always written
/// UTF-16LE (encoding 2) on the little-endian devices this library targets,
/// matching `write_mhod_type_3`'s `G_LITTLE_ENDIAN` branch.
public struct ArtworkMHOD: Equatable {
    public var chunk: Chunk

    public init?(_ chunk: Chunk) {
        guard chunk.tag == "mhod" else { return nil }
        self.chunk = chunk
    }

    private var h: Data { chunk.headerBytes }

    /// Well-known ArtworkDB MHOD types, cross-checked against libgpod's
    /// `enum MhodArtworkType` and iOpenPod's `ArtworkMhodType`.
    public enum Kind: Int16, Sendable {
        case albumName = 1
        case thumbnailImage = 2
        case fileName = 3
        case fullResImage = 5
    }

    public var type: Int16 { h.leI16(at: 12) ?? 0 }
    public var kind: Kind? { Kind(rawValue: type) }

    private static let stringKinds: Set<Kind> = [.albumName, .fileName]
    public var isStringType: Bool { kind.map { Self.stringKinds.contains($0) } ?? false }

    /// The decoded string payload, for `.albumName`/`.fileName`. `nil` for
    /// container kinds, or if the payload is malformed.
    public var stringValue: String? {
        guard isStringType else { return nil }
        let payload = chunk.trailingBytes
        guard let byteLength = payload.leU32(at: 0), let encoding = payload.leU8(at: 4) else { return nil }
        let start = 12
        let end = start + Int(byteLength)
        guard end <= payload.count, start <= end else { return nil }
        let textStart = payload.startIndex + start
        let textEnd = payload.startIndex + end
        let text = payload[textStart..<textEnd]
        if encoding == 2 {
            return String(data: text, encoding: .utf16LittleEndian)
        }
        return String(data: text, encoding: .utf8)
    }

    /// The wrapped chunk, for the `.thumbnailImage`/`.fullResImage` container
    /// kinds (an `mhni` for thumbnails). `nil` for string kinds.
    public var wrappedChunk: Chunk? {
        guard !isStringType else { return nil }
        return chunk.children.first
    }

    // MARK: - Construction

    /// Header size for every ArtworkDB "mhod", regardless of kind: 24 bytes.
    /// See the type doc above for why this is smaller than the string
    /// variant's real fixed portion.
    public static let headerLen: UInt32 = 24

    private static func makeHeader(kind: Kind, payloadLength: Int) -> Data {
        var w = ByteWriter()
        w.fourCC("mhod")
        w.u32(headerLen)
        w.u32(UInt32(Int(headerLen) + payloadLength)) // totalLen
        w.i16(kind.rawValue)
        w.i16(0) // unknown
        w.u32(0) // unknown
        w.u32(0) // unknown
        precondition(w.count == Int(headerLen))
        return w.finalize()
    }

    /// Builds a container "mhod" (`.thumbnailImage`/`.fullResImage`) wrapping
    /// `child` (an `mhni` chunk, e.g. from `MHNI.make`).
    public static func makeContainer(kind: Kind, wrapping child: Chunk) -> Chunk {
        precondition(!stringKinds.contains(kind), "\(kind) is a string kind, not a container kind")
        let headerBytes = makeHeader(kind: kind, payloadLength: child.serializedByteCount)
        return Chunk(tag: "mhod", headerLen: headerLen, headerBytes: headerBytes, children: [child], trailingBytes: Data())
    }

    /// Builds a string "mhod" (`.albumName`/`.fileName`). `.fileName` is
    /// always encoded UTF-16LE; `.albumName` UTF-8 — matching
    /// `write_mhod_type_3`'s little-endian branch and `write_mhod_type_1`
    /// respectively.
    public static func makeString(kind: Kind, value: String) -> Chunk {
        precondition(stringKinds.contains(kind), "\(kind) is a container kind, not a string kind")

        let encoding: UInt8 = kind == .fileName ? 2 : 1
        let encoded: [UInt8]
        if encoding == 2 {
            encoded = Array(value.data(using: .utf16LittleEndian) ?? Data())
        } else {
            encoded = Array(value.utf8)
        }
        let padding = (4 - (encoded.count % 4)) % 4

        var payload = ByteWriter()
        payload.u32(UInt32(encoded.count))
        payload.u8(encoding)
        payload.zeros(3) // unknown
        payload.zeros(4) // unknown
        payload.data(Data(encoded))
        payload.zeros(padding)
        let payloadData = payload.finalize()

        let headerBytes = makeHeader(kind: kind, payloadLength: payloadData.count)
        return Chunk(tag: "mhod", headerLen: headerLen, headerBytes: headerBytes, children: [], trailingBytes: payloadData)
    }
}
