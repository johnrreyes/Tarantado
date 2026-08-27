import Foundation

/// Typed view over an "mhfd" chunk — the root of an ArtworkDB
/// (`iPod_Control/Artwork/ArtworkDB`), structurally the artwork-database
/// counterpart to iTunesDB's "mhbd" root: offset 20 is a derived count of
/// child `mhsd` sections, recomputed by `ChunkTag.derivedCountFields` the
/// same way `mhbd`'s is (see `ChunkFamily.swift`).
///
/// Field offsets cross-checked against libgpod's `_MhfdHeader` in
/// `db-itunes-parser.h`.
///
/// ```
/// 0  tag "mhfd"
/// 4  headerLen (u32)
/// 8  totalLen  (u32)
/// 12 unknown1  (u32)
/// 16 unknown2  (u32) — MUST be 2. libgpod's own header comment: iTunes 7+
///    deletes the *entire* ArtworkDB outright if it finds 1 here.
/// 20 numberOfSections (u32) — count of child mhsd chunks
/// 24 unknown3  (u32)
/// 28 nextID    (u32) — next `mhii.imageID` to allocate; iTunes conventionally starts at 100
/// 32 unknown5  (u64)
/// 40 unknown6  (u64)
/// 48 four unknown flag bytes
/// 52 unknown8  (u32)
/// 56 unknown9  (u32)
/// 60 unknown10 (u32)
/// 64 unknown11 (u32)
/// ```
public struct MHFD: Equatable {
    public var chunk: Chunk

    public init?(_ chunk: Chunk) {
        guard chunk.tag == "mhfd" else { return nil }
        self.chunk = chunk
    }

    private var h: Data { chunk.headerBytes }

    public var numberOfSections: UInt32 { h.leU32(at: 20) ?? 0 }
    public var nextID: UInt32 { h.leU32(at: 28) ?? 0 }

    public var sections: [Chunk] { chunk.children(tag: "mhsd") }

    // MARK: - Construction

    /// Header size used by freshly-built `mhfd` chunks: 132 bytes, matching
    /// iOpenPod's `MHFD_HEADER_SIZE` (real iTunes output).
    public static let defaultHeaderLen: UInt32 = 132

    /// Builds a fresh ArtworkDB root wrapping `sections` (its `mhsd`
    /// children — see `ArtworkDatabase.makeEmpty`, which builds the
    /// conventional three: image list, empty photo-album list, file list).
    ///
    /// `nextImageID` seeds the `mhii.imageID` allocator.
    public static func make(sections: [Chunk], nextImageID: UInt32) -> Chunk {
        var w = ByteWriter()
        w.fourCC("mhfd")
        w.u32(defaultHeaderLen)
        w.u32(0) // totalLen, patched below
        w.u32(0) // unknown1
        w.u32(2) // unknown2 -- must be 2, see type doc above
        w.u32(UInt32(sections.count)) // numberOfSections, +20
        w.u32(0) // unknown3
        w.u32(nextImageID) // +28
        w.u64(0) // unknown5
        w.u64(0) // unknown6
        w.u8(0)
        w.u8(0)
        w.u8(0)
        w.u8(0) // four unknown flag bytes
        w.u32(0) // unknown8
        w.u32(0) // unknown9
        w.u32(0) // unknown10
        w.u32(0) // unknown11
        w.zeros(Int(defaultHeaderLen) - w.count)

        precondition(w.count == Int(defaultHeaderLen))
        var headerBytes = w.finalize()

        let childrenLen = sections.reduce(0) { $0 + $1.serializedByteCount }
        headerBytes.setLE(UInt32(Int(defaultHeaderLen) + childrenLen), at: 8)

        return Chunk(tag: "mhfd", headerLen: defaultHeaderLen, headerBytes: headerBytes, children: sections, trailingBytes: Data())
    }
}
