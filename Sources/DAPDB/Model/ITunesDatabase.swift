import Foundation

/// A parsed iTunesDB, as a typed façade over the underlying (still fully
/// accessible) generic chunk tree.
public struct ITunesDatabase: Equatable {
    /// The full generic chunk tree ("mhbd" at the root). Anything not yet
    /// exposed by a typed accessor is still reachable here.
    public var root: Chunk

    public init(root: Chunk) {
        self.root = root
    }

    public init(parsing data: Data) throws {
        self.root = try ChunkTree.parse(data)
    }

    public func serialized() -> Data {
        ChunkTree.serialize(root)
    }

    // MARK: - Reading

    private var trackListChunk: Chunk? {
        root.firstDescendant { $0.tag == "mhlt" }
    }

    public var trackChunks: [Chunk] {
        trackListChunk?.children(tag: "mhit") ?? []
    }

    public var tracks: [Track] {
        trackChunks.compactMap(MHIT.init).map(Track.init(from:))
    }

    public var playlistChunks: [Chunk] {
        // Playlists can live under more than one mhsd section in the wild
        // (this golden fixture has the master playlist mirrored across two),
        // so this collects every mhyp anywhere in the tree, in document order.
        var result: [Chunk] = []
        func walk(_ chunk: Chunk) {
            if chunk.tag == "mhyp" { result.append(chunk) }
            for child in chunk.children { walk(child) }
        }
        walk(root)
        return result
    }

    public var playlists: [Playlist] {
        playlistChunks.compactMap(MHYP.init).map(Playlist.init(from:))
    }

    /// One `mhsd` section of the database that contains playlists, tagged
    /// with the section type stored at the section's offset 12.
    public struct PlaylistSection: Equatable, Sendable {
        /// The `mhsd` section type: 1 = tracks, 4 = albums, and several
        /// distinct values carry playlists. Which of those the firmware
        /// treats as authoritative is device-specific and not something
        /// this library assumes — see `playlistSections`.
        public let sectionType: UInt32
        public let playlists: [Playlist]

        public init(sectionType: UInt32, playlists: [Playlist]) {
            self.sectionType = sectionType
            self.playlists = playlists
        }
    }

    /// Playlists grouped by the `mhsd` section holding them, in document
    /// order. `playlists` deliberately flattens this, which hides a real
    /// property of databases in the wild: the master playlist is commonly
    /// *mirrored* across two sections under one persistent ID, and the two
    /// copies can hold different entries. Anything reasoning about which
    /// copy the firmware actually reads needs the section, not the flat list.
    public var playlistSections: [PlaylistSection] {
        root.children(tag: "mhsd").compactMap { section in
            var found: [Chunk] = []
            func walk(_ chunk: Chunk) {
                if chunk.tag == "mhyp" { found.append(chunk) }
                for child in chunk.children { walk(child) }
            }
            walk(section)
            guard !found.isEmpty else { return nil }
            return PlaylistSection(
                sectionType: section.headerBytes.leU32(at: 12) ?? 0,
                playlists: found.compactMap(MHYP.init).map(Playlist.init(from:))
            )
        }
    }

    // MARK: - Mutation (Deliverable 3)

    /// Appends a new track (as an `mhit` chunk, e.g. built with `MHIT.make`)
    /// to the track list.
    public mutating func addTrack(_ track: Chunk) throws {
        root = try ChunkMutation.addingTrack(track, to: root)
    }

    /// Removes the track with the given `uniqueID`, and every playlist entry
    /// that referenced it.
    public mutating func removeTrack(uniqueID: UInt32) throws {
        root = try ChunkMutation.removingTrack(uniqueID: uniqueID, from: root)
    }

    /// Appends a new entry (as an `mhip` chunk, e.g. built with `MHIP.make`)
    /// to the playlist with the given persistent ID.
    public mutating func addPlaylistEntry(_ entry: Chunk, toPlaylistID id: UInt64) throws {
        root = try ChunkMutation.addingPlaylistEntry(entry, toPlaylistID: id, in: root)
    }

    /// Removes the entry referencing `trackID` from the playlist with the given ID.
    public mutating func removePlaylistEntry(trackID: UInt32, fromPlaylistID id: UInt64) throws {
        root = try ChunkMutation.removingPlaylistEntry(trackID: trackID, fromPlaylistID: id, in: root)
    }

    // MARK: - Mutation (playlists)

    /// Errors from the whole-playlist (as opposed to per-entry) mutation API
    /// below. Distinct from `ChunkMutationError` because these encode a
    /// safety policy — smart playlists and the master playlist are
    /// read-only through this API — on top of `ChunkMutation`'s purely
    /// structural operations.
    public enum PlaylistEditError: Error, Equatable, Sendable {
        case playlistNotFound(UInt64)
        /// The master playlist can't be renamed, deleted, or reordered
        /// through this API (it always contains every track on the device).
        case cannotModifyMasterPlaylist(UInt64)
        /// Smart playlist rules (mhod type 50/51) are opaque and never
        /// reinterpreted or rewritten by this library — see `MHOD.Kind`.
        case cannotModifySmartPlaylist(UInt64)
        /// `reorderPlaylist`'s new order isn't a permutation of the
        /// playlist's current track IDs.
        case reorderTrackSetMismatch(UInt64)
    }

    private func mhyp(id: UInt64) -> MHYP? {
        playlistChunks.first { MHYP($0)?.id == id }.flatMap(MHYP.init)
    }

    /// Creates a new, empty regular (non-smart, non-master) playlist titled
    /// `title` and returns its freshly-allocated persistent ID. The ID is
    /// chosen at random and checked against every playlist ID already in
    /// the tree (64-bit ID space, so a collision is effectively
    /// impossible, but this stays correct even in that case).
    @discardableResult
    public mutating func addPlaylist(title: String, inSectionType sectionType: UInt32? = nil) throws -> UInt64 {
        var usedIDs = Set(playlists.map(\.id))
        var id = UInt64.random(in: 1...UInt64.max)
        while usedIDs.contains(id) { id = UInt64.random(in: 1...UInt64.max) }
        usedIDs.insert(id)

        let chunk = MHYP.make(id: id, title: title)
        if let sectionType {
            root = try ChunkMutation.addingPlaylist(chunk, toSectionType: sectionType, in: root)
        } else {
            root = try ChunkMutation.addingPlaylist(chunk, to: root)
        }
        return id
    }

    /// Deletes the regular playlist with the given `id`. Throws if the
    /// playlist doesn't exist, is the master playlist, or is a smart
    /// playlist.
    public mutating func removePlaylist(id: UInt64) throws {
        guard let mhyp = mhyp(id: id) else { throw PlaylistEditError.playlistNotFound(id) }
        guard !mhyp.isMaster else { throw PlaylistEditError.cannotModifyMasterPlaylist(id) }
        guard !mhyp.isSmart else { throw PlaylistEditError.cannotModifySmartPlaylist(id) }
        root = ChunkMutation.removingPlaylist(id: id, from: root)
    }

    /// Renames the regular playlist with the given `id`. Throws if the
    /// playlist doesn't exist, is the master playlist, or is a smart
    /// playlist.
    public mutating func renamePlaylist(id: UInt64, to newTitle: String) throws {
        guard let mhyp = mhyp(id: id) else { throw PlaylistEditError.playlistNotFound(id) }
        guard !mhyp.isMaster else { throw PlaylistEditError.cannotModifyMasterPlaylist(id) }
        guard !mhyp.isSmart else { throw PlaylistEditError.cannotModifySmartPlaylist(id) }
        root = try ChunkMutation.renamingPlaylist(id: id, to: newTitle, in: root)
    }

    /// Reorders the regular playlist with the given `id` so its tracks
    /// appear in exactly `trackIDsInOrder`, which must be a permutation of
    /// the playlist's current track IDs. Throws if the playlist doesn't
    /// exist, is the master playlist, is a smart playlist, or if
    /// `trackIDsInOrder` doesn't contain exactly the same set of track IDs
    /// the playlist currently has.
    public mutating func reorderPlaylist(id: UInt64, trackIDsInOrder newOrder: [UInt32]) throws {
        guard let mhyp = mhyp(id: id) else { throw PlaylistEditError.playlistNotFound(id) }
        guard !mhyp.isMaster else { throw PlaylistEditError.cannotModifyMasterPlaylist(id) }
        guard !mhyp.isSmart else { throw PlaylistEditError.cannotModifySmartPlaylist(id) }
        guard Set(newOrder) == Set(mhyp.trackIDsInOrder) else { throw PlaylistEditError.reorderTrackSetMismatch(id) }
        root = try ChunkMutation.reorderingPlaylist(id: id, trackIDsInOrder: newOrder, in: root)
    }
}
