import Foundation

/// Errors thrown while parsing or navigating the iTunesDB binary chunk format.
///
/// These conform to `LocalizedError` because they surface directly in the app's
/// UI. Without it, a thrown `DAPDBError` bridges to `NSError` and
/// `localizedDescription` degrades to the useless
/// "The operation couldn't be completed. (DAPDB.DAPDBError error 2.)" — which
/// is exactly what a user reported hitting on a 5G iPod Video, discarding the
/// tag/offset detail the error already carried.
public enum DAPDBError: Error, Equatable, Sendable {
    /// Not enough bytes remained at `offset` to satisfy a read of `requested` bytes.
    case truncated(offset: Int, requested: Int, available: Int)
    /// A seek or slice was attempted outside the bounds of the buffer.
    case invalidRange(offset: Int, length: Int)
    /// A chunk's header declared a length/count that is internally inconsistent
    /// (e.g. `headerLen` smaller than the minimum required, or `totalLen` smaller
    /// than `headerLen`, or `totalLen` extending past the end of the buffer).
    case malformedChunk(String)
}

extension DAPDBError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .truncated(let offset, let requested, let available):
            return "The database ends unexpectedly: \(requested) byte(s) were needed at offset \(offset), " +
                "but only \(available) remain. The file is truncated or was only partly written."
        case .invalidRange(let offset, let length):
            return "Attempted to read \(length) byte(s) at offset \(offset), which lies outside the database."
        case .malformedChunk(let detail):
            return "The database contains a chunk this app can't make sense of: \(detail)"
        }
    }
}

/// A parse failure located within the chunk tree.
///
/// `DAPDBError` alone says *what* went wrong but not *where* in the tree — and
/// "where" is the only thing that makes a report from a device we don't have in
/// hand actionable. This wraps the underlying error with the ancestor path, the
/// absolute byte offset, and a short hex window at the failure point, so a
/// screenshot from a user is enough to identify the offending chunk.
///
/// The hex window is deliberately small and always sits at a chunk *header*,
/// which is structural data (tags, lengths, IDs) rather than the user's track
/// metadata.
public struct ChunkParseFailure: Error, LocalizedError, Equatable, Sendable {
    /// Ancestor chain to the failure, e.g. `"mhbd@0 > mhsd@244 > mhlt@528"`.
    public let path: String
    /// Absolute byte offset into the database where parsing stopped.
    public let offset: Int
    /// The structural problem found there.
    public let underlying: DAPDBError
    /// Up to 16 bytes at `offset`, hex-encoded, or `""` past the end of the file.
    public let nearbyBytes: String

    public init(path: String, offset: Int, underlying: DAPDBError, nearbyBytes: String) {
        self.path = path
        self.offset = offset
        self.underlying = underlying
        self.nearbyBytes = nearbyBytes
    }

    public var errorDescription: String? {
        var message = "Couldn't read this DAP's iTunes database.\n\n"
        message += (underlying.errorDescription ?? "\(underlying)") + "\n\n"
        message += "Location: \(path.isEmpty ? "(root)" : path)\nByte offset: \(offset)"
        if !nearbyBytes.isEmpty {
            message += "\nBytes here: \(nearbyBytes)"
        }
        message += "\n\nYour music and database were left unchanged. Please send these details to the developer."
        return message
    }

    /// Builds a failure at `offset`, capturing the hex window from `bytes`.
    static func at(
        offset: Int,
        path: [String],
        underlying: DAPDBError,
        bytes: [UInt8]
    ) -> ChunkParseFailure {
        ChunkParseFailure(
            path: path.joined(separator: " > "),
            offset: offset,
            underlying: underlying,
            nearbyBytes: hexWindow(bytes, at: offset)
        )
    }

    /// Hex-encodes up to `length` bytes starting at `offset`, clamped to the buffer.
    static func hexWindow(_ bytes: [UInt8], at offset: Int, length: Int = 16) -> String {
        guard offset >= 0, offset < bytes.count else { return "" }
        let end = min(offset + length, bytes.count)
        return bytes[offset..<end]
            .map { String(format: "%02x", $0) }
            .joined(separator: " ")
    }
}
