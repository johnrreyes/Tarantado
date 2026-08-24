import Foundation

/// A plain-value snapshot of an `mhyp` chunk's commonly-used fields.
public struct Playlist: Equatable, Sendable {
    public var id: UInt64
    public var title: String?
    public var isMaster: Bool
    /// `true` for a smart playlist (rules live in opaque, byte-preserved
    /// mhod type 50/51 blobs — see `MHYP.isSmart`). Smart playlists are
    /// read-only: creating/renaming/deleting/reordering only ever applies
    /// to regular playlists.
    public var isSmart: Bool
    public var timestamp: Date?
    /// Track IDs (`Track.uniqueID` values), in playlist order.
    public var trackIDsInOrder: [UInt32]

    public init(from mhyp: MHYP) {
        id = mhyp.id
        title = mhyp.title
        isMaster = mhyp.isMaster
        isSmart = mhyp.isSmart
        timestamp = mhyp.timestamp
        trackIDsInOrder = mhyp.trackIDsInOrder
    }
}
