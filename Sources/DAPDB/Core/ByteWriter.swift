import Foundation

/// The write-side mirror of `ByteReader`: an append-only little-endian byte
/// buffer, with the ability to patch an already-written 8/16/32/64-bit field
/// (used to fill in `totalLen`/count fields once the size of what follows is
/// known).
public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public var count: Int { bytes.count }

    public mutating func u8(_ v: UInt8) {
        bytes.append(v)
    }

    public mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xff))
        bytes.append(UInt8((v >> 8) & 0xff))
    }

    public mutating func u32(_ v: UInt32) {
        for i in 0..<4 { bytes.append(UInt8((v >> (8 * i)) & 0xff)) }
    }

    public mutating func u64(_ v: UInt64) {
        for i in 0..<8 { bytes.append(UInt8((v >> (8 * i)) & 0xff)) }
    }

    /// A 4-byte ASCII chunk tag, e.g. "mhod". Traps if `tag` is not exactly 4 ASCII bytes.
    public mutating func fourCC(_ tag: String) {
        let ascii = Array(tag.utf8)
        precondition(ascii.count == 4, "fourCC tag must be exactly 4 bytes, got \(tag)")
        bytes.append(contentsOf: ascii)
    }

    public mutating func data(_ d: Data) {
        bytes.append(contentsOf: d)
    }

    public mutating func zeros(_ n: Int) {
        bytes.append(contentsOf: repeatElement(0, count: n))
    }

    /// Overwrites 4 bytes already written at `offset` with a new little-endian value.
    public mutating func setU32(_ v: UInt32, at offset: Int) {
        precondition(offset >= 0 && offset + 4 <= bytes.count)
        for i in 0..<4 { bytes[offset + i] = UInt8((v >> (8 * i)) & 0xff) }
    }

    public func finalize() -> Data {
        Data(bytes)
    }
}
