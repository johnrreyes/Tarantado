import Foundation

/// Typed view over an "mhii" chunk — one artwork image entry in ArtworkDB's
/// image list. There is exactly one of these per **track** that carries
/// artwork (not one per unique image — libgpod's own writer emits one `mhii`
/// per track unconditionally; see `write_mhli` in `db-artwork-writer.c`),
/// correlated to its track by `songID`, which equals that track's
/// `MHIT.dbid`. Multiple tracks sharing identical embedded art can still
/// each get their own `mhii` while pointing their `mhni` children at the
/// same underlying `.ithmb` bytes — see the module's Phase 2/3 notes on
/// dedup by content hash.
///
/// Field offsets cross-checked against libgpod's `_MhiiHeader` in
/// `db-itunes-parser.h` (marked `__attribute__((packed))` there specifically
/// so the 64-bit `songID` doesn't get realigned) and `write_mhii` in
/// `db-artwork-writer.c`.
///
/// ```
/// 0  tag "mhii"
/// 4  headerLen (u32)
/// 8  totalLen  (u32)
/// 12 mhod count (u32) — number of child mhod (container) chunks, one per thumbnail format
/// 16 imageID    (u32) — this database's local ID for the image, from mhfd.nextID
/// 20 songID     (u64) — == the correlated track's MHIT.dbid
/// 28 unknown4   (u32)
/// 32 rating     (u32)
/// 36 unknown6   (u32)
/// 40 origDate       (u32, Mac epoch)
/// 44 digitizedDate  (u32, Mac epoch)
/// 48 origImgSize (u32) — byte size of the *source* image (e.g. the embedded
///    JPEG), not any generated thumbnail. Also mirrored into the
///    correlated track's `MHIT.artworkSize`.
/// ```
public struct MHII: Equatable {
    public var chunk: Chunk

    public init?(_ chunk: Chunk) {
        guard chunk.tag == "mhii" else { return nil }
        self.chunk = chunk
    }

    private var h: Data { chunk.headerBytes }

    public var imageID: UInt32 { h.leU32(at: 16) ?? 0 }
    public var songID: UInt64 { h.leU64(at: 20) ?? 0 }
    public var rating: UInt32 { h.leU32(at: 32) ?? 0 }
    public var origDate: Date? { MacEpoch.date(fromRaw: h.leU32(at: 40) ?? 0) }
    public var digitizedDate: Date? { MacEpoch.date(fromRaw: h.leU32(at: 44) ?? 0) }
    public var origImageSize: UInt32 { h.leU32(at: 48) ?? 0 }

    /// This image's thumbnails, one per format, unwrapped from their
    /// container `mhod`s.
    public var thumbnails: [MHNI] {
        chunk.children(tag: "mhod")
            .compactMap(ArtworkMHOD.init)
            .filter { $0.kind == .thumbnailImage }
            .compactMap { $0.wrappedChunk }
            .compactMap(MHNI.init)
    }

    public func thumbnail(formatID: UInt32) -> MHNI? {
        thumbnails.first { $0.formatID == formatID }
    }

    // MARK: - Construction

    /// Header size used by freshly-built `mhii` chunks: 152 bytes, matching
    /// iOpenPod's `MHII_HEADER_SIZE` (real iTunes output) and the same value
    /// already used for the hand-built `mhii` fixture in
    /// `ImageListParsingTests.swift`.
    public static let defaultHeaderLen: UInt32 = 152

    /// All the fields a freshly-built `mhii` needs.
    public struct Fields {
        public var imageID: UInt32
        public var songID: UInt64
        public var rating: UInt32 = 0
        public var origDate: Date? = nil
        public var digitizedDate: Date? = nil
        /// Byte size of the source image (e.g. the embedded JPEG this
        /// artwork was extracted from). Should match the correlated track's
        /// `MHIT.Fields.artworkSize`.
        public var origImageSize: UInt32 = 0

        public init(imageID: UInt32, songID: UInt64) {
            self.imageID = imageID
            self.songID = songID
        }
    }

    /// Builds a new "mhii" chunk. `thumbnails` are already-built `mhni`
    /// chunks (e.g. from `MHNI.make`) — one per thumbnail format this image
    /// carries; each is wrapped in its container `mhod` internally, the
    /// caller never has to know about `ArtworkMHOD`.
    public static func make(_ fields: Fields, thumbnails: [Chunk]) -> Chunk {
        var w = ByteWriter()
        w.fourCC("mhii")
        w.u32(defaultHeaderLen)
        w.u32(0) // totalLen, patched below
        w.u32(0) // mhod count, patched below

        w.u32(fields.imageID) // +16
        w.u64(fields.songID) // +20
        w.u32(0) // unknown4 +28
        w.u32(fields.rating) // +32
        w.u32(0) // unknown6 +36
        w.u32(MacEpoch.raw(from: fields.origDate)) // +40
        w.u32(MacEpoch.raw(from: fields.digitizedDate)) // +44
        w.u32(fields.origImageSize) // +48
        w.zeros(Int(defaultHeaderLen) - w.count)

        precondition(w.count == Int(defaultHeaderLen))
        var headerBytes = w.finalize()

        let children = thumbnails.map { ArtworkMHOD.makeContainer(kind: .thumbnailImage, wrapping: $0) }
        let childrenLen = children.reduce(0) { $0 + $1.serializedByteCount }
        headerBytes.setLE(UInt32(Int(defaultHeaderLen) + childrenLen), at: 8)
        headerBytes.setLE(UInt32(children.count), at: 12)

        return Chunk(tag: "mhii", headerLen: defaultHeaderLen, headerBytes: headerBytes, children: children, trailingBytes: Data())
    }
}
