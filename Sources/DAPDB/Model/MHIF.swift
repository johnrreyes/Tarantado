import Foundation

/// Typed view over an "mhif" chunk — one entry in ArtworkDB's file list
/// (`mhsd` type `.fileList` → `mhlf` → one `mhif` per thumbnail format this
/// device supports, *not* one per actual `.ithmb` file on disk — a format
/// that outgrows one file rolls over into `F<id>_2.ithmb`, `_3.ithmb`, ...
/// all still described by the same single `mhif`).
///
/// Field offsets cross-checked against libgpod's `_MhifHeader` in
/// `db-itunes-parser.h` and `write_mhif` in `db-artwork-writer.c`, which
/// computes `imageSize` as `format.height * format.width * 2` (2 bytes/pixel
/// for the RGB565 formats this library targets).
///
/// ```
/// 0  tag "mhif"
/// 4  headerLen (u32)
/// 8  totalLen  (u32)
/// 12 unknown1  (u32)
/// 16 formatID  (u32) — matches the `mhni.formatID` of thumbnails in this file
/// 20 imageSize (u32) — per-thumbnail byte size for this format (width*height*2)
/// ```
public struct MHIF: Equatable {
    public var chunk: Chunk

    public init?(_ chunk: Chunk) {
        guard chunk.tag == "mhif" else { return nil }
        self.chunk = chunk
    }

    private var h: Data { chunk.headerBytes }

    public var formatID: UInt32 { h.leU32(at: 16) ?? 0 }
    public var imageSize: UInt32 { h.leU32(at: 20) ?? 0 }

    // MARK: - Construction

    /// Header size used by freshly-built `mhif` chunks: 124 bytes, matching
    /// iOpenPod's `MHIF_HEADER_SIZE` (real iTunes output).
    public static let defaultHeaderLen: UInt32 = 124

    public static func make(formatID: UInt32, imageSize: UInt32) -> Chunk {
        var w = ByteWriter()
        w.fourCC("mhif")
        w.u32(defaultHeaderLen)
        w.u32(defaultHeaderLen) // totalLen -- mhif has no children
        w.u32(0) // unknown1
        w.u32(formatID) // +16
        w.u32(imageSize) // +20
        w.zeros(Int(defaultHeaderLen) - w.count)

        precondition(w.count == Int(defaultHeaderLen))
        return Chunk(tag: "mhif", headerLen: defaultHeaderLen, headerBytes: w.finalize(), children: [], trailingBytes: Data())
    }
}
