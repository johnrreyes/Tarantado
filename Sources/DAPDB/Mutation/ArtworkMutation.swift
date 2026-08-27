import Foundation

/// Errors specific to the ArtworkDB mutation API.
public enum ArtworkMutationError: Error, Equatable, Sendable {
    /// The tree has no "mhli" (image list) section to add an image to.
    case noImageList
}

/// Structural mutation of a parsed ArtworkDB chunk tree. The artwork-database
/// counterpart to `ChunkMutation`, but much simpler: unlike iTunesDB, a real
/// ArtworkDB carries exactly one image list, never mirrored across sections,
/// so this doesn't need `ChunkMutation.addingPlaylist(toSectionType:)`'s
/// section-targeted search to avoid an ambiguous match.
public enum ArtworkMutation {
    /// Appends `image` (an "mhii" chunk, e.g. from `MHII.make`) to the tree's
    /// image list.
    public static func addingImage(_ image: Chunk, to root: Chunk) throws -> Chunk {
        precondition(image.tag == "mhii", "expected an mhii chunk")
        let (result, changed) = root.transformingFirstDescendant(matching: { $0.tag == "mhli" }) { mhli in
            var mhli = mhli
            mhli.children.append(image)
            return mhli
        }
        guard changed else { throw ArtworkMutationError.noImageList }
        return result
    }

    /// Removes every `mhii` whose `songID` matches `dbid` (a removed track's
    /// `MHIT.dbid`) from the image list. Mirrors `ChunkMutation
    /// .removingPlaylistEntries`'s "clean up dangling references on removal"
    /// role for iTunesDB, but for the images list here.
    public static func removingImage(songID dbid: UInt64, from root: Chunk) -> Chunk {
        root.transformingAllDescendants(matching: { $0.tag == "mhli" }) { mhli in
            var mhli = mhli
            mhli.children.removeAll { MHII($0)?.songID == dbid }
            return mhli
        }
    }
}
