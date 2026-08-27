import Foundation

/// Generic, lossless parsing and serialization of the iTunesDB chunk tree.
///
/// `parse` never interprets field *meaning* — it only walks the tag/headerLen/
/// totalLen-or-count structure common to every chunk family, capturing
/// everything it doesn't otherwise account for as `trailingBytes`. `serialize`
/// is the exact inverse: concatenate `headerBytes`, then each child
/// (recursively), then `trailingBytes`. An unmodified parse+serialize
/// round-trip is therefore byte-for-byte identical to the input by
/// construction, not by chance.
///
/// Every structural failure is reported as a `ChunkParseFailure`, which pairs
/// the underlying `DAPDBError` with the ancestor path and byte offset where the
/// walk stopped. Databases written by iTunes for devices we can't test against
/// are the main source of surprises here, and "which chunk, at what offset" is
/// the difference between an actionable bug report and a shrug.
public enum ChunkTree {
    /// Parses `data` as a single root chunk (normally "mhbd").
    public static func parse(_ data: Data) throws -> Chunk {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else {
            throw ChunkParseFailure.at(
                offset: 0,
                path: [],
                underlying: .truncated(offset: 0, requested: 8, available: bytes.count),
                bytes: bytes
            )
        }
        var (root, next) = try parseChunk(bytes, at: 0, path: [])
        // Defensive: if the root's own totalLen doesn't cover the whole
        // buffer, preserve whatever is left as trailing bytes so parsing
        // never silently drops data. For a well-formed iTunesDB, next == bytes.count.
        if next < bytes.count {
            root.trailingBytes.append(Data(bytes[next..<bytes.count]))
        }
        return root
    }

    /// Serializes a chunk tree back to bytes. Pure structural recursion over
    /// `headerBytes` / `children` / `trailingBytes` — see the type doc above.
    public static func serialize(_ chunk: Chunk) -> Data {
        var out = Data()
        out.reserveCapacity(chunk.serializedByteCount)
        appendSerialized(chunk, into: &out)
        return out
    }

    private static func appendSerialized(_ chunk: Chunk, into out: inout Data) {
        out.append(chunk.headerBytes)
        for child in chunk.children {
            appendSerialized(child, into: &out)
        }
        out.append(chunk.trailingBytes)
    }

    /// Returns true if the two bytes at `offset` look like the start of a
    /// chunk tag (all iTunesDB tags observed in the wild start with "mh").
    /// Used to decide, while scanning a sized container's children, whether
    /// the bytes remaining before `totalLen` are another child chunk or just
    /// padding/unparsed trailing data.
    private static func looksLikeTag(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard offset + 2 <= bytes.count else { return false }
        return bytes[offset] == UInt8(ascii: "m") && bytes[offset + 1] == UInt8(ascii: "h")
    }

    /// Renders a 4-byte tag for use in an error message, escaping anything
    /// non-printable. When the walk misaligns, the "tag" is garbage, and
    /// showing its bytes is far more diagnostic than showing U+FFFD.
    private static func displayTag(_ bytes: [UInt8], at offset: Int) -> String {
        let end = min(offset + 4, bytes.count)
        guard offset < end else { return "(past end of file)" }
        let slice = bytes[offset..<end]
        let printable = slice.allSatisfy { $0 >= 0x20 && $0 < 0x7f }
        if printable {
            return String(decoding: slice, as: UTF8.self)
        }
        return "0x" + slice.map { String(format: "%02x", $0) }.joined()
    }

    /// Parses one chunk starting at `offset`. Returns the chunk and the offset
    /// immediately following it (its "extent end"). `path` is the ancestor
    /// chain used to locate failures; it never affects parsing.
    private static func parseChunk(
        _ bytes: [UInt8],
        at offset: Int,
        path: [String]
    ) throws -> (Chunk, Int) {
        func fail(_ underlying: DAPDBError, at failureOffset: Int = offset) -> ChunkParseFailure {
            ChunkParseFailure.at(offset: failureOffset, path: path, underlying: underlying, bytes: bytes)
        }

        guard offset + 8 <= bytes.count else {
            throw fail(.truncated(offset: offset, requested: 8, available: bytes.count - offset))
        }
        let tag = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
        let shownTag = displayTag(bytes, at: offset)
        let here = path + ["\(shownTag)@\(offset)"]

        func failHere(_ underlying: DAPDBError, at failureOffset: Int = offset) -> ChunkParseFailure {
            ChunkParseFailure.at(offset: failureOffset, path: here, underlying: underlying, bytes: bytes)
        }

        let headerLen = Int(readU32(bytes, offset + 4))
        guard headerLen >= 8 else {
            throw failHere(.malformedChunk("\(shownTag) at offset \(offset): headerLen \(headerLen) < 8"))
        }
        guard offset + headerLen <= bytes.count else {
            throw failHere(.truncated(offset: offset, requested: headerLen, available: bytes.count - offset))
        }
        let headerBytes = Data(bytes[offset..<offset + headerLen])

        switch ChunkTag.family(for: tag) {
        case .sizedContainer:
            guard offset + 12 <= bytes.count else {
                throw failHere(.truncated(offset: offset, requested: 12, available: bytes.count - offset))
            }
            let totalLen = Int(readU32(bytes, offset + 8))
            guard totalLen >= headerLen else {
                throw failHere(.malformedChunk(
                    "\(shownTag) at offset \(offset): totalLen \(totalLen) < headerLen \(headerLen). " +
                    "Either this chunk is corrupt, or its tag stores a child count at offset 8 " +
                    "rather than a total length and this app is reading it as the wrong shape."
                ))
            }
            let extentEnd = offset + totalLen
            guard extentEnd <= bytes.count else {
                throw failHere(.truncated(offset: offset, requested: totalLen, available: bytes.count - offset))
            }

            var children: [Chunk] = []
            var cursor = offset + headerLen
            while cursor < extentEnd {
                guard cursor + 8 <= extentEnd, looksLikeTag(bytes, at: cursor) else { break }
                let (child, next) = try parseChunk(bytes, at: cursor, path: here)
                guard next <= extentEnd else { break }
                children.append(child)
                cursor = next
            }
            let trailing = Data(bytes[cursor..<extentEnd])
            let chunk = Chunk(tag: tag, headerLen: UInt32(headerLen), headerBytes: headerBytes, children: children, trailingBytes: trailing)
            return (chunk, extentEnd)

        case .countedList:
            guard offset + 12 <= bytes.count else {
                throw failHere(.truncated(offset: offset, requested: 12, available: bytes.count - offset))
            }
            let count = readU32(bytes, offset + 8)
            var children: [Chunk] = []
            var cursor = offset + headerLen
            for index in 0..<count {
                // A counted list carries no extent of its own, so a count that
                // disagrees with what actually follows would otherwise walk the
                // parser off into arbitrary bytes and surface as a confusing
                // failure deep in a neighbouring chunk. Check that each child
                // position really begins a chunk, and blame the list if not.
                guard cursor + 8 <= bytes.count, looksLikeTag(bytes, at: cursor) else {
                    throw failHere(.malformedChunk(
                        "\(shownTag) at offset \(offset) declares \(count) child chunk(s), but child " +
                        "\(index) at offset \(cursor) doesn't begin with a chunk tag " +
                        "(found \(displayTag(bytes, at: cursor)))."
                    ), at: cursor)
                }
                let (child, next) = try parseChunk(bytes, at: cursor, path: here)
                children.append(child)
                cursor = next
            }
            let chunk = Chunk(tag: tag, headerLen: UInt32(headerLen), headerBytes: headerBytes, children: children, trailingBytes: Data())
            return (chunk, cursor)

        case .opaqueLeaf:
            // Extent is exactly headerLen -- no children, no trailing
            // region, and offset 8 is ordinary payload data (already
            // captured in headerBytes above), not a length or count.
            let chunk = Chunk(tag: tag, headerLen: UInt32(headerLen), headerBytes: headerBytes, children: [], trailingBytes: Data())
            return (chunk, offset + headerLen)
        }
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * i) }
        return v
    }
}
