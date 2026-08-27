import Foundation

/// Typed view over an "mhni" chunk — one thumbnail *format* rendition of a
/// single artwork image (an `mhii`'s child, by way of a wrapping
/// `ArtworkMHOD` container). A track's cover art typically has two of these
/// on a 5G iPod: format 1028 (100×100) and 1029 (200×200).
///
/// Field offsets cross-checked against libgpod's `_MhniHeader` in
/// `db-itunes-parser.h` and `write_mhni` in `db-artwork-writer.c`, with two
/// additions (`unk1`, `imageSize2`) confirmed only by iOpenPod's
/// `artworkdb_shared/mhni.py::read_mhni_fields`, which reads them from real
/// on-device captures — libgpod's own writer never sets them (they come
/// through as zero when it writes), but real iTunes/iPod output has
/// `imageSize2` duplicating `imageSize`. Writing both is the conservative
/// choice: match what real iTunes emits rather than what the open-source
/// writer historically did.
///
/// ```
/// 0  tag "mhni"
/// 4  headerLen (u32)
/// 8  totalLen  (u32) = header + the one child mhod (filename)
/// 12 mhod count (u32) — always 1
/// 16 formatID   (u32) — an `Itdb_ArtworkFormat.format_id`, e.g. 1029
/// 20 ithmbOffset (u32) — byte offset of this thumbnail's pixels in its .ithmb file
/// 24 imageSize  (u32) — byte size of this thumbnail's pixel data
/// 28 verticalPadding   (i16)
/// 30 horizontalPadding (i16)
/// 32 imageHeight (u16) — padding-inclusive; see `write_mhni` in ithumb-writer.c
/// 34 imageWidth  (u16) — padding-inclusive
/// 36 unk1        (u32) — observed zero
/// 40 imageSize2  (u32) — observed to duplicate `imageSize`
/// ```
public struct MHNI: Equatable {
    public var chunk: Chunk

    public init?(_ chunk: Chunk) {
        guard chunk.tag == "mhni" else { return nil }
        self.chunk = chunk
    }

    private var h: Data { chunk.headerBytes }

    public var formatID: UInt32 { h.leU32(at: 16) ?? 0 }
    public var ithmbOffset: UInt32 { h.leU32(at: 20) ?? 0 }
    public var imageSize: UInt32 { h.leU32(at: 24) ?? 0 }
    public var verticalPadding: Int16 { h.leI16(at: 28) ?? 0 }
    public var horizontalPadding: Int16 { h.leI16(at: 30) ?? 0 }
    public var imageHeight: UInt16 { h.leU16(at: 32) ?? 0 }
    public var imageWidth: UInt16 { h.leU16(at: 34) ?? 0 }

    /// The `.ithmb` path this thumbnail's pixels live in (e.g.
    /// `:F1029_1.ithmb`), carried by the sole child `mhod` (type `.fileName`).
    public var ithmbFileName: String? {
        chunk.children(tag: "mhod").compactMap(ArtworkMHOD.init).first { $0.kind == .fileName }?.stringValue
    }

    // MARK: - Construction

    /// Header size used by freshly-built `mhni` chunks: 76 bytes, matching
    /// iOpenPod's `MHNI_HEADER_SIZE` (real iTunes output; comfortably covers
    /// every field above, offset 40 being the last).
    public static let defaultHeaderLen: UInt32 = 76

    /// Builds a new "mhni" chunk describing one thumbnail format's location
    /// and geometry, plus the `.ithmb` filename that holds its pixels.
    ///
    /// `imageWidth`/`imageHeight` are padding-**inclusive** — pass the full
    /// packed dimensions (format width/height when the source image was
    /// scaled to fit without filling the square; see `Itdb_ArtworkFormat`'s
    /// `crop` doc in `itdb_device.h`), not the pre-padding scaled size.
    public static func make(
        formatID: UInt32,
        ithmbOffset: UInt32,
        imageSize: UInt32,
        imageWidth: UInt16,
        imageHeight: UInt16,
        horizontalPadding: Int16 = 0,
        verticalPadding: Int16 = 0,
        ithmbFileName: String
    ) -> Chunk {
        var w = ByteWriter()
        w.fourCC("mhni")
        w.u32(defaultHeaderLen)
        w.u32(0) // totalLen, patched below
        w.u32(1) // mhod count: just the filename mhod
        w.u32(formatID) // +16
        w.u32(ithmbOffset) // +20
        w.u32(imageSize) // +24
        w.i16(verticalPadding) // +28
        w.i16(horizontalPadding) // +30
        w.u16(imageHeight) // +32
        w.u16(imageWidth) // +34
        w.u32(0) // unk1 +36
        w.u32(imageSize) // imageSize2 +40, duplicates imageSize -- see type doc
        w.zeros(Int(defaultHeaderLen) - w.count)

        precondition(w.count == Int(defaultHeaderLen))
        var headerBytes = w.finalize()

        let filenameMHOD = ArtworkMHOD.makeString(kind: .fileName, value: ithmbFileName)
        headerBytes.setLE(UInt32(Int(defaultHeaderLen) + filenameMHOD.serializedByteCount), at: 8)

        return Chunk(tag: "mhni", headerLen: defaultHeaderLen, headerBytes: headerBytes, children: [filenameMHOD], trailingBytes: Data())
    }
}
