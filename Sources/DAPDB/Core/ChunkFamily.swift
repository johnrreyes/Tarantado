import Foundation

/// The two header shapes used by iTunesDB chunks. What lives at byte offset 8
/// (right after the tag and `headerLen`) depends entirely on which family a
/// chunk's tag belongs to — this is the single most important thing to get
/// right when navigating the format.
enum ChunkFamily {
    /// Offset 8 is `totalLen`: header + all children + trailing bytes. The
    /// chunk's extent is `[offset, offset + totalLen)`; children are parsed by
    /// walking that range starting at `offset + headerLen`.
    case sizedContainer

    /// Offset 8 is a child *count*, not a length. There is no `totalLen` at
    /// all — children begin at `offset + headerLen` and parsing stops after
    /// exactly `count` children have been read. The chunk's extent is
    /// whatever byte range those children actually occupy.
    case countedList
}

enum ChunkTag {
    /// Tags whose header stores a child count (not a total length) at offset 8.
    ///
    /// Per the iTunesDB spec these are the "list header" chunks, named "mhl"
    /// plus one letter for whatever they list: mhlt (tracks), mhlp (playlists),
    /// mhla (albums), mhli (images), mhlf (image files).
    ///
    /// `mhli` was added after a 5G iPod Video in the field failed to connect
    /// with "mhli at offset 1219986: totalLen 23 < headerLen 92" — the 23 was
    /// its image count being read as a byte length. Album art was introduced
    /// with the 5G, so no earlier device's database can contain one.
    ///
    /// NOTE: `mhia` (an individual album entry, analogous to `mhit`/`mhyp`) is
    /// deliberately *not* included here even though some secondary references
    /// group it with the family-B list headers. libgpod's `itdb_itunesdb.c`
    /// writes `mhia` with `fix_mhit(cts, mhia_seek, mhod_num)` — the exact same
    /// helper used for `mhit` — which patches offset 8 with the total byte
    /// size of the whole chunk (`cts->pos - mhia_seek`) and offset 12 with the
    /// mhod child count. That is the family-A ("sized container") shape, not
    /// family B. Since `mhia` never appears in the golden fixture (its `mhla`
    /// list has count 0), this can't be confirmed against real bytes, but the
    /// authoritative C source is unambiguous on the write side, so `mhia` is
    /// classified as `.sizedContainer` (the default) below.
    static let countedListTags: Set<String> = ["mhlt", "mhlp", "mhla", "mhli", "mhlf"]

    static func family(for tag: String) -> ChunkFamily {
        if countedListTags.contains(tag) { return .countedList }
        // Unknown "mhl?" tags follow the same naming convention as every list
        // header above, so guess family B rather than fail the whole database.
        // Guessing wrong here is recoverable — a counted list with a bogus
        // count fails with a located error naming the tag — whereas guessing
        // sizedContainer on a real list header is exactly the bug that made a
        // 5G iPod unreadable. Note "mhia" is not "mhl?" and is unaffected.
        if tag.count == 4 && tag.hasPrefix("mhl") { return .countedList }
        return .sizedContainer
    }

    /// For sized-container tags that additionally store one or more child
    /// counts inside their header (beyond the universal `totalLen` at offset
    /// 8), the offset of each such field and which children it counts.
    /// These are all confirmed against libgpod's `mk_*`/`get_*` functions.
    struct DerivedCountField {
        let offset: Int
        let countsChildrenWithTag: String
    }

    static func derivedCountFields(for tag: String) -> [DerivedCountField] {
        switch tag {
        case "mhbd":
            // offset 20: number of top-level mhsd sections.
            return [DerivedCountField(offset: 20, countsChildrenWithTag: "mhsd")]
        case "mhit", "mhia", "mhip":
            // offset 12: number of child mhod chunks.
            return [DerivedCountField(offset: 12, countsChildrenWithTag: "mhod")]
        case "mhyp":
            // offset 12: number of child mhod chunks; offset 16: number of child mhip chunks.
            return [
                DerivedCountField(offset: 12, countsChildrenWithTag: "mhod"),
                DerivedCountField(offset: 16, countsChildrenWithTag: "mhip"),
            ]
        default:
            // mhsd's offset 12 is a section *type* tag (1=tracks, 2=playlists, ...),
            // and mhod's offset 12 is its MHOD type — neither is a derived count,
            // so neither is touched by recomputation.
            return []
        }
    }
}

extension Chunk {
    /// Recomputes this chunk's own derived header fields (`totalLen` and/or
    /// child-count fields) from its *current* `children`/`trailingBytes`,
    /// leaving everything else in `headerBytes` untouched. Does not recurse —
    /// callers that mutate a chunk deep in the tree are expected to call this
    /// on every ancestor from the mutated node up to the root (the
    /// `transformingFirstDescendant`/`transformingAllDescendants` helpers in
    /// `ChunkMutation` do this automatically).
    mutating func recomputeDerivedFields() {
        switch ChunkTag.family(for: tag) {
        case .countedList:
            headerBytes.setLE(UInt32(children.count), at: 8)
        case .sizedContainer:
            let total = serializedByteCount
            headerBytes.setLE(UInt32(total), at: 8)
            for field in ChunkTag.derivedCountFields(for: tag) {
                let n = children.filter { $0.tag == field.countsChildrenWithTag }.count
                headerBytes.setLE(UInt32(n), at: field.offset)
            }
        }
    }
}
