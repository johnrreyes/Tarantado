import Foundation

/// Typed view over an "mhip" chunk (one playlist entry — a reference to a
/// track by ID, plus its position within the playlist). Field offsets
/// cross-checked against libgpod's `get_mhip`/`mk_mhip` in `itdb_itunesdb.c`.
/// `headerLen` is 76 (0x4c) in files written by modern iTunes/libgpod (the
/// minimum libgpod accepts on read is 36).
///
/// ```
/// 0  tag "mhip"
/// 4  headerLen (u32)
/// 8  totalLen  (u32)
/// 12 mhod count (u32)
/// 16 podcastGroupFlag (u32)
/// 20 podcastGroupID (u32)
/// 24 trackID (u32) — the referenced mhit's `uniqueID`, not its `dbid`
/// 28 timestamp (u32, Mac epoch)
/// 32 podcastGroupRef (u32)
/// ```
public struct MHIP: Equatable {
    public var chunk: Chunk

    public init?(_ chunk: Chunk) {
        guard chunk.tag == "mhip" else { return nil }
        self.chunk = chunk
    }

    private var h: Data { chunk.headerBytes }

    /// The referenced track's `MHIT.uniqueID`.
    public var trackID: UInt32 { h.leU32(at: 24) ?? 0 }
    public var podcastGroupFlag: UInt32 { h.leU32(at: 16) ?? 0 }
    public var podcastGroupID: UInt32 { h.leU32(at: 20) ?? 0 }
    public var timestamp: Date? { MacEpoch.date(fromRaw: h.leU32(at: 28) ?? 0) }
    public var podcastGroupRef: UInt32 { h.leU32(at: 32) ?? 0 }

    public var mhods: [MHOD] { chunk.children(tag: "mhod").compactMap(MHOD.init) }

    /// Header size used by freshly-built mhip chunks: 76 bytes (0x4c), matching
    /// libgpod's `mk_mhip`.
    public static let defaultHeaderLen: UInt32 = 76

    /// Builds a new "mhip" chunk referencing `trackID` at the given playlist `position`.
    public static func make(trackID: UInt32, position: UInt32, timestamp: Date? = nil) -> Chunk {
        let positionMHOD = MHOD.makePlaylistPosition(position)

        var w = ByteWriter()
        w.fourCC("mhip")
        w.u32(defaultHeaderLen)
        w.u32(0) // totalLen, patched below
        w.u32(1) // mhod count: just the position mhod
        w.u32(0) // podcastGroupFlag
        w.u32(0) // podcastGroupID
        w.u32(trackID) // +24
        w.u32(MacEpoch.raw(from: timestamp)) // +28
        w.u32(0) // podcastGroupRef +32
        w.zeros(Int(defaultHeaderLen) - w.count)

        precondition(w.count == Int(defaultHeaderLen))
        var headerBytes = w.finalize()
        headerBytes.setLE(UInt32(Int(defaultHeaderLen) + positionMHOD.serializedByteCount), at: 8)

        return Chunk(tag: "mhip", headerLen: defaultHeaderLen, headerBytes: headerBytes, children: [positionMHOD], trailingBytes: Data())
    }
}
