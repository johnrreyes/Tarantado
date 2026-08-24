import Foundation

/// Typed view over an "mhyp" chunk (one playlist). Field offsets cross-checked
/// against libgpod's `get_playlist`/`mk_mhyp`-equivalent code in
/// `itdb_itunesdb.c`. `headerLen` is 184 (0xb8) in files written by modern
/// iTunes/libgpod (and in the golden fixture); everything here is
/// bounds-checked against the chunk's actual `headerBytes`.
///
/// ```
/// 0  tag "mhyp"
/// 4  headerLen (u32)
/// 8  totalLen  (u32) = header + all child mhod/mhip chunks
/// 12 mhod count (u32)
/// 16 mhip count (u32) — number of tracks in the playlist
/// 20 type  (u8)  — 0 = normal, 1 = master (contains every track)
/// 21 flag1 (u8)
/// 22 flag2 (u8)
/// 23 flag3 (u8)
/// 24 timestamp (u32, Mac epoch)
/// 28 id (u64) — persistent playlist ID; what `mhip`... no, what an entry's
///    parent mhyp is looked up by when appending/removing tracks
/// 42 podcastFlag (u16)
/// 44 sortOrder (u32)
/// 0x50 mhsd5Type (u16) — only valid when headerLen >= 0x6c
/// ```
public struct MHYP: Equatable {
    public var chunk: Chunk

    public init?(_ chunk: Chunk) {
        guard chunk.tag == "mhyp" else { return nil }
        self.chunk = chunk
    }

    private var h: Data { chunk.headerBytes }

    /// Persistent playlist ID.
    public var id: UInt64 { h.leU64(at: 28) ?? 0 }
    public var type: UInt8 { h.leU8(at: 20) ?? 0 }
    public var isMaster: Bool { type == 1 }
    public var timestamp: Date? { MacEpoch.date(fromRaw: h.leU32(at: 24) ?? 0) }
    public var podcastFlag: UInt16 { h.leU16(at: 42) ?? 0 }
    public var sortOrder: UInt32 { h.leU32(at: 44) ?? 0 }

    public var mhods: [MHOD] { chunk.children(tag: "mhod").compactMap(MHOD.init) }
    public var mhips: [MHIP] { chunk.children(tag: "mhip").compactMap(MHIP.init) }

    public var title: String? {
        mhods.first { $0.kind == .title }?.stringValue
    }

    /// `true` if this playlist carries smart-playlist prefs/rules (mhod
    /// types 50/51). Smart playlists are read-only throughout this library —
    /// their rule blobs are opaque and never reinterpreted or rewritten; see
    /// `MHOD.Kind.smartPlaylistPrefs`/`.smartPlaylistRules`.
    public var isSmart: Bool {
        mhods.contains { $0.kind == .smartPlaylistPrefs || $0.kind == .smartPlaylistRules }
    }

    /// Track IDs (`MHIT.uniqueID` values) in the order the device will play
    /// them: the physical order of the `mhip` children.
    ///
    /// Deliberately *not* sorted by each entry's `.playlistPosition` mhod.
    /// Verified on the reference mini 2G 2026-08-18: a playlist whose
    /// position mhods said one order while its children sat in another was
    /// displayed in **child** order. Sorting by position here would make
    /// this accessor — and so `dapctl playlist show`, and the app — report
    /// an order the device does not agree with, which is exactly how a
    /// broken reorder came back reported as a success.
    ///
    /// `ChunkMutation.reorderingPlaylist` keeps the two encodings in
    /// agreement on everything this library writes, so the distinction only
    /// bites on databases written by something else.
    public var trackIDsInOrder: [UInt32] {
        mhips.map(\.trackID)
    }

    // MARK: - Construction

    /// Header size used by freshly-built mhyp chunks: 184 bytes (0xb8),
    /// matching the golden fixture's own playlists (see the type doc above).
    public static let defaultHeaderLen: UInt32 = 184

    /// Builds a new "mhyp" chunk for a regular (non-smart) playlist, with a
    /// single title `mhod` child and no entries yet (add tracks afterwards
    /// with `MHIP.make` + `ChunkMutation.addingPlaylistEntry`/
    /// `ITunesDatabase.addPlaylistEntry`).
    ///
    /// Deliberately does not attempt to reproduce the golden fixture's extra
    /// opaque mhod children (types 100/102 — iTunes view-preference blobs;
    /// see `MHOD.Kind.playlistPosition`'s doc) or the unused
    /// `podcastFlag`/`sortOrder`/`mhsd5Type` header fields beyond
    /// zero-filling them: those are cosmetic iTunes-desktop artifacts, not
    /// something classic iPod firmware is known to require, and this
    /// mirrors how `MHIT.make` already only builds the fields this library
    /// actually needs rather than every field libgpod's writer emits.
    public static func make(id: UInt64, title: String, type: UInt8 = 0, timestamp: Date? = nil, sortOrder: UInt32 = 0) -> Chunk {
        var w = ByteWriter()
        w.fourCC("mhyp")
        w.u32(defaultHeaderLen)
        w.u32(0) // totalLen, patched below
        w.u32(0) // mhod count, patched below
        w.u32(0) // mhip count, patched below
        w.u8(type) // +20: 0 = normal, 1 = master
        w.u8(0) // flag1 +21
        w.u8(0) // flag2 +22
        w.u8(0) // flag3 +23
        w.u32(MacEpoch.raw(from: timestamp)) // +24
        w.u64(id) // +28
        w.zeros(6) // +36...41, unknown
        w.u16(0) // podcastFlag +42
        w.u32(sortOrder) // +44
        w.zeros(Int(defaultHeaderLen) - w.count) // pad to 184 (covers mhsd5Type @0x50, left zero)

        precondition(w.count == Int(defaultHeaderLen))
        var headerBytes = w.finalize()

        let children: [Chunk] = [MHOD.makeString(kind: .title, value: title)]
        let childrenLen = children.reduce(0) { $0 + $1.serializedByteCount }
        headerBytes.setLE(UInt32(Int(defaultHeaderLen) + childrenLen), at: 8) // totalLen
        headerBytes.setLE(UInt32(children.count), at: 12) // mhod count
        headerBytes.setLE(UInt32(0), at: 16) // mhip count

        return Chunk(tag: "mhyp", headerLen: defaultHeaderLen, headerBytes: headerBytes, children: children, trailingBytes: Data())
    }
}
