import Foundation

/// Errors specific to the mutation API.
public enum ChunkMutationError: Error, Equatable, Sendable {
    /// The tree has no `mhlt` (track list) section to add/remove a track from.
    case noTrackList
    /// The tree has no `mhlp` (playlist list) section to add a playlist to.
    case noPlaylistList
    /// No playlist with the given ID exists in the tree.
    case playlistNotFound(UInt64)
    /// No `mhsd` section of the requested type contains an `mhlp`.
    case noPlaylistListInSection(UInt32)
}

/// Structural mutation of a parsed chunk tree: adding/removing tracks in the
/// track list, adding/removing entries in a playlist, with every affected
/// `totalLen`/count field recomputed bottom-up automatically (see
/// `Chunk.transformingFirstDescendant`/`transformingAllDescendants`).
///
/// These are free functions over `Chunk` (not methods on `ITunesDatabase`)
/// because they only need generic tree navigation — `ITunesDatabase` exposes
/// friendlier wrappers around them.
public enum ChunkMutation {
    /// Appends `track` (an `mhit` chunk, e.g. from `MHIT.make`) to the tree's
    /// track list.
    public static func addingTrack(_ track: Chunk, to root: Chunk) throws -> Chunk {
        precondition(track.tag == "mhit", "expected an mhit chunk")
        let (result, changed) = root.transformingFirstDescendant(matching: { $0.tag == "mhlt" }) { mhlt in
            var mhlt = mhlt
            mhlt.children.append(track)
            return mhlt
        }
        guard changed else { throw ChunkMutationError.noTrackList }
        return result
    }

    /// Removes the track with the given `uniqueID` from the track list, and
    /// removes every `mhip` entry (in every playlist) that referenced it.
    public static func removingTrack(uniqueID: UInt32, from root: Chunk) throws -> Chunk {
        let (afterTrackRemoval, changed) = root.transformingFirstDescendant(matching: { $0.tag == "mhlt" }) { mhlt in
            var mhlt = mhlt
            mhlt.children.removeAll { MHIT($0)?.uniqueID == uniqueID }
            return mhlt
        }
        guard changed else { throw ChunkMutationError.noTrackList }
        return removingPlaylistEntries(referencingTrackID: uniqueID, from: afterTrackRemoval)
    }

    /// Removes every `mhip` (in every playlist, anywhere in the tree) that
    /// references `trackID`, renumbering the survivors' `playlistPosition`
    /// mhods so they stay contiguous.
    ///
    /// Exposed separately since it's also useful on its own (e.g. cleaning
    /// up dangling references after an out-of-band track removal).
    ///
    /// The renumbering is for consistency, not correctness: the firmware
    /// reads child order and ignores these values entirely (see
    /// `reorderingPlaylist`), and a gapped playlist was confirmed to display
    /// correctly on the reference mini 2G. But this library's own invariant
    /// is that the two encodings of order never disagree, and leaving holes
    /// here would break it for every playlist a removed track belonged to.
    public static func removingPlaylistEntries(referencingTrackID trackID: UInt32, from root: Chunk) -> Chunk {
        root.transformingAllDescendants(matching: { $0.tag == "mhyp" }) { mhyp in
            var mhyp = mhyp
            let hadEntry = mhyp.children.contains { $0.tag == "mhip" && MHIP($0)?.trackID == trackID }
            guard hadEntry else { return mhyp }

            mhyp.children.removeAll { $0.tag == "mhip" && MHIP($0)?.trackID == trackID }

            var index: UInt32 = 0
            mhyp.children = mhyp.children.map { child in
                guard child.tag == "mhip" else { return child }
                defer { index += 1 }
                var updated = child
                let position = index
                updated.children = updated.children.map { grandchild in
                    guard grandchild.tag == "mhod", MHOD(grandchild)?.kind == .playlistPosition else { return grandchild }
                    return MHOD.makePlaylistPosition(position)
                }
                return updated
            }
            return mhyp
        }
    }

    /// Appends `entry` (an `mhip` chunk, e.g. from `MHIP.make`) to the
    /// playlist with the given persistent `id`.
    public static func addingPlaylistEntry(_ entry: Chunk, toPlaylistID id: UInt64, in root: Chunk) throws -> Chunk {
        precondition(entry.tag == "mhip", "expected an mhip chunk")
        let (result, changed) = root.transformingFirstDescendant(matching: { $0.tag == "mhyp" && MHYP($0)?.id == id }) { mhyp in
            var mhyp = mhyp
            mhyp.children.append(entry)
            return mhyp
        }
        guard changed else { throw ChunkMutationError.playlistNotFound(id) }
        return result
    }

    /// Removes every entry referencing `trackID` from the playlist with the given `id`.
    public static func removingPlaylistEntry(trackID: UInt32, fromPlaylistID id: UInt64, in root: Chunk) throws -> Chunk {
        let (result, changed) = root.transformingFirstDescendant(matching: { $0.tag == "mhyp" && MHYP($0)?.id == id }) { mhyp in
            var mhyp = mhyp
            mhyp.children.removeAll { $0.tag == "mhip" && MHIP($0)?.trackID == trackID }
            return mhyp
        }
        guard changed else { throw ChunkMutationError.playlistNotFound(id) }
        return result
    }

    // MARK: - Playlists (whole mhyp, Deliverable "playlists")

    /// Locates the "primary" playlist list (`mhlp`) chunk that new playlists
    /// should be inserted into.
    ///
    /// Real hardware iTunesDBs can contain more than one `mhlp` — the golden
    /// fixture mirrors its master playlist, byte-for-byte, across two
    /// separate `mhsd` sections, in addition to a third `mhsd` holding its
    /// two genuine, distinct (smart) playlists. A master-only mirror always
    /// has exactly one child; the `mhlp` that actually holds browsable,
    /// non-mirrored playlists is whichever one has the most children. Falls
    /// back to the first (only) `mhlp` found when there's just one in the
    /// tree, which is the common case for a real device.
    static func primaryPlaylistListChunk(in root: Chunk) -> Chunk? {
        var all: [Chunk] = []
        func walk(_ chunk: Chunk) {
            if chunk.tag == "mhlp" { all.append(chunk) }
            for child in chunk.children { walk(child) }
        }
        walk(root)
        return all.max { $0.children.count < $1.children.count }
    }

    /// Appends `playlist` to the `mhlp` inside the `mhsd` section whose type
    /// tag (offset 12) is `sectionType`.
    ///
    /// Which section a device's firmware actually reads its playlists from
    /// is not something this library can infer from the bytes — a database
    /// in the wild mirrors its master playlist across two sections, and the
    /// section holding the most playlists is not necessarily the browsable
    /// one. `addingPlaylist(_:to:)`'s heuristic is a guess; this is the
    /// escape hatch for callers that know (or are trying to determine)
    /// which section is authoritative for their hardware.
    public static func addingPlaylist(
        _ playlist: Chunk,
        toSectionType sectionType: UInt32,
        in root: Chunk
    ) throws -> Chunk {
        precondition(playlist.tag == "mhyp", "expected an mhyp chunk")

        // Locate the section by its position among the root's children, and
        // rewrite only inside that subtree.
        //
        // The obvious implementation — find the target `mhlp` chunk, then
        // search the whole tree for a chunk matching it — is wrong here, and
        // wrong in exactly the case this overload exists to handle. `Chunk`
        // is `Equatable` by value, and a database that mirrors its master
        // playlist across two `mhsd` sections has two byte-identical `mhlp`
        // chunks. An equality-based search then appends to whichever mirror
        // comes first in file order, silently ignoring `sectionType`:
        // observed on the reference iPod 4G, where a playlist requested in
        // section 2 landed in section 3.
        guard let sectionIndex = root.children.firstIndex(where: { section in
            section.tag == "mhsd"
                && section.headerBytes.leU32(at: 12) == sectionType
                && section.firstDescendant(where: { $0.tag == "mhlp" }) != nil
        }) else {
            throw ChunkMutationError.noPlaylistListInSection(sectionType)
        }

        let (updatedSection, changed) = root.children[sectionIndex]
            .transformingFirstDescendant(matching: { $0.tag == "mhlp" }) { mhlp in
                var mhlp = mhlp
                mhlp.children.append(playlist)
                return mhlp
            }
        guard changed else { throw ChunkMutationError.noPlaylistListInSection(sectionType) }

        var result = root
        result.children[sectionIndex] = updatedSection
        // `transformingFirstDescendant` fixes up derived fields as it
        // unwinds, but it unwound to the section, not to the root.
        result.recomputeDerivedFields()
        return result
    }

    /// Appends `playlist` (an `mhyp` chunk, e.g. from `MHYP.make`) to the
    /// tree's primary playlist list (see `primaryPlaylistListChunk`).
    public static func addingPlaylist(_ playlist: Chunk, to root: Chunk) throws -> Chunk {
        precondition(playlist.tag == "mhyp", "expected an mhyp chunk")
        guard let target = primaryPlaylistListChunk(in: root) else {
            throw ChunkMutationError.noPlaylistList
        }
        let (result, changed) = root.transformingFirstDescendant(matching: { $0.tag == "mhlp" && $0 == target }) { mhlp in
            var mhlp = mhlp
            mhlp.children.append(playlist)
            return mhlp
        }
        guard changed else { throw ChunkMutationError.noPlaylistList }
        return result
    }

    /// Removes the playlist (`mhyp`) with the given persistent `id` from
    /// every `mhlp` anywhere in the tree that contains it (mirroring how
    /// `removingPlaylistEntries` sweeps every `mhyp` for a removed track —
    /// a playlist shouldn't normally appear under more than one `mhlp`, but
    /// this stays correct even if it does). Callers that need to refuse
    /// removing the master or a smart playlist should check that before
    /// calling this — this function is purely structural, like the rest of
    /// `ChunkMutation`.
    public static func removingPlaylist(id: UInt64, from root: Chunk) -> Chunk {
        root.transformingAllDescendants(matching: { $0.tag == "mhlp" }) { mhlp in
            var mhlp = mhlp
            mhlp.children.removeAll { $0.tag == "mhyp" && MHYP($0)?.id == id }
            return mhlp
        }
    }

    /// Replaces the title `mhod` (inserting one at the front if somehow
    /// missing) of the playlist with the given `id`.
    public static func renamingPlaylist(id: UInt64, to newTitle: String, in root: Chunk) throws -> Chunk {
        let (result, changed) = root.transformingFirstDescendant(matching: { $0.tag == "mhyp" && MHYP($0)?.id == id }) { mhyp in
            var mhyp = mhyp
            let newTitleChunk = MHOD.makeString(kind: .title, value: newTitle)
            if let index = mhyp.children.firstIndex(where: { $0.tag == "mhod" && MHOD($0)?.kind == .title }) {
                mhyp.children[index] = newTitleChunk
            } else {
                mhyp.children.insert(newTitleChunk, at: 0)
            }
            return mhyp
        }
        guard changed else { throw ChunkMutationError.playlistNotFound(id) }
        return result
    }

    /// Reorders the playlist with the given `id` so its entries appear in
    /// `newOrder`, by physically reordering its `mhip` children **and**
    /// renumbering their `playlistPosition` mhods to match.
    ///
    /// Both, because the firmware only honours one of them. Verified on the
    /// reference mini 2G 2026-08-18: a playlist whose position mhods were
    /// rewritten to reverse it, while its `mhip` children stayed in their
    /// original order, displayed in the **original** order on the device.
    /// The position mhod is not what the firmware sorts by — child order is.
    ///
    /// The positions are kept consistent anyway so that the two encodings of
    /// order never disagree; a reader that trusts either one gets the same
    /// answer. (libgpod writes them in agreement too.)
    ///
    /// Entries whose track ID doesn't appear in `newOrder` keep their
    /// relative order and sort to the end — callers are expected to pass a
    /// permutation (see `ITunesDatabase.reorderPlaylist`, which validates
    /// that), so this only decides the shape of an already-invalid call.
    public static func reorderingPlaylist(id: UInt64, trackIDsInOrder newOrder: [UInt32], in root: Chunk) throws -> Chunk {
        var rankByTrackID: [UInt32: Int] = [:]
        for (index, trackID) in newOrder.enumerated() { rankByTrackID[trackID] = index }

        let (result, changed) = root.transformingFirstDescendant(matching: { $0.tag == "mhyp" && MHYP($0)?.id == id }) { mhyp in
            var mhyp = mhyp

            // An mhyp's children are its mhods (title, and any opaque blobs
            // we preserve verbatim) followed by its mhip entries. Only the
            // entries move; everything else keeps its place.
            let others = mhyp.children.filter { $0.tag != "mhip" }
            let entries = mhyp.children.filter { $0.tag == "mhip" }

            // Sorted by rank, ties broken by existing position so the sort
            // is stable — Swift's `sort` is not, and an unstable shuffle of
            // entries that share a rank would silently reorder a playlist
            // the caller asked to leave alone.
            let reordered = entries.enumerated().sorted { lhs, rhs in
                let lhsRank = MHIP(lhs.element).flatMap { rankByTrackID[$0.trackID] } ?? Int.max
                let rhsRank = MHIP(rhs.element).flatMap { rankByTrackID[$0.trackID] } ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }.map(\.element)

            mhyp.children = others + reordered.enumerated().map { index, child in
                var updated = child
                updated.children = updated.children.map { grandchild in
                    guard grandchild.tag == "mhod", MHOD(grandchild)?.kind == .playlistPosition else { return grandchild }
                    return MHOD.makePlaylistPosition(UInt32(index))
                }
                return updated
            }
            return mhyp
        }
        guard changed else { throw ChunkMutationError.playlistNotFound(id) }
        return result
    }
}
