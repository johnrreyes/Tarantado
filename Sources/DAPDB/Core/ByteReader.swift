import Foundation

/// A little-endian, bounds-checked cursor over a fixed byte buffer.
///
/// All multi-byte integers in the iTunesDB format are little-endian, regardless
/// of host platform. `ByteReader` never reads past the end of its buffer; every
/// read is checked and throws `DAPDBError.truncated` on failure.
public struct ByteReader {
    /// The full underlying buffer, copied once into a plain array so that every
    /// offset is guaranteed to be zero-based (unlike `Data`, whose `startIndex`
    /// is not guaranteed to be 0 after slicing).
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ data: Data, offset: Int = 0) {
        self.bytes = [UInt8](data)
        self.offset = offset
    }

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var count: Int { bytes.count }
    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    public mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= bytes.count else {
            throw DAPDBError.invalidRange(offset: newOffset, length: 0)
        }
        offset = newOffset
    }

    private func requireAvailable(_ n: Int) throws {
        guard n >= 0, offset >= 0, offset <= bytes.count, n <= bytes.count - offset else {
            throw DAPDBError.truncated(
                offset: offset,
                requested: n,
                available: max(0, bytes.count - offset)
            )
        }
    }

    public mutating func u8() throws -> UInt8 {
        try requireAvailable(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    /// Little-endian 16-bit unsigned integer.
    public mutating func u16() throws -> UInt16 {
        try requireAvailable(2)
        let v = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2
        return v
    }

    /// Little-endian 32-bit unsigned integer.
    public mutating func u32() throws -> UInt32 {
        try requireAvailable(4)
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * i) }
        offset += 4
        return v
    }

    /// Little-endian 64-bit unsigned integer.
    public mutating func u64() throws -> UInt64 {
        try requireAvailable(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * i) }
        offset += 8
        return v
    }

    /// A 4-byte ASCII chunk tag, e.g. "mhbd".
    public mutating func fourCC() throws -> String {
        try requireAvailable(4)
        let slice = bytes[offset..<offset + 4]
        offset += 4
        return String(decoding: slice, as: UTF8.self)
    }

    /// Reads `n` raw bytes and advances the cursor.
    public mutating func bytes(_ n: Int) throws -> Data {
        try requireAvailable(n)
        let slice = Data(bytes[offset..<offset + n])
        offset += n
        return slice
    }

    /// Reads `n` raw bytes at an absolute offset without moving the cursor.
    public func peek(_ n: Int, at customOffset: Int) -> Data? {
        guard customOffset >= 0, n >= 0, customOffset + n <= bytes.count else { return nil }
        return Data(bytes[customOffset..<customOffset + n])
    }
}
