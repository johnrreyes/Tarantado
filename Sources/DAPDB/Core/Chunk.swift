import Foundation

/// A single node in the generic, lossless iTunesDB chunk tree.
///
/// Every chunk in the format begins with a 4-byte ASCII tag ("mhbd", "mhod", ...)
/// followed by a `UInt32` `headerLen`. `headerBytes` holds the complete raw
/// header — all `headerLen` bytes, including the tag and length fields
/// themselves. Re-serializing a `Chunk` is just: emit `headerBytes` verbatim,
/// then each child (recursively), then `trailingBytes`. Because `headerBytes`
/// is preserved byte-for-byte unless explicitly mutated, round-tripping an
/// unmodified tree reproduces the original file exactly, including any
/// header bytes this library doesn't (yet) interpret.
public struct Chunk: Equatable, Sendable {
    /// The 4-character ASCII tag, e.g. "mhbd", "mhod".
    public var tag: String

    /// The header length as declared in the chunk itself (bytes [4, 8)).
    /// Invariant: `headerBytes.count == Int(headerLen)`.
    public var headerLen: UInt32

    /// The complete raw header, exactly `headerLen` bytes, starting with the
    /// tag. Fields this library understands (totalLen, counts, typed values)
    /// live at fixed offsets inside this buffer; everything else is preserved
    /// verbatim.
    public var headerBytes: Data

    /// Nested chunks, in file order.
    public var children: [Chunk]

    /// Any bytes belonging to this chunk that aren't accounted for by
    /// `headerBytes` or `children` — e.g. inline payload data for leaf chunks
    /// like `mhod` (string/opaque contents), or padding between the last
    /// child and a sized container's declared `totalLen`.
    public var trailingBytes: Data

    public init(tag: String, headerLen: UInt32, headerBytes: Data, children: [Chunk] = [], trailingBytes: Data = Data()) {
        self.tag = tag
        self.headerLen = headerLen
        self.headerBytes = headerBytes
        self.children = children
        self.trailingBytes = trailingBytes
    }

    /// Total serialized size of this chunk (header + all descendants + trailing bytes).
    public var serializedByteCount: Int {
        headerBytes.count + children.reduce(0) { $0 + $1.serializedByteCount } + trailingBytes.count
    }

    public func firstChild(tag: String) -> Chunk? {
        children.first { $0.tag == tag }
    }

    public func children(tag: String) -> [Chunk] {
        children.filter { $0.tag == tag }
    }

    /// Depth-first (pre-order) search for the first descendant (including `self`)
    /// satisfying `predicate`.
    public func firstDescendant(where predicate: (Chunk) -> Bool) -> Chunk? {
        if predicate(self) { return self }
        for child in children {
            if let found = child.firstDescendant(where: predicate) { return found }
        }
        return nil
    }
}
