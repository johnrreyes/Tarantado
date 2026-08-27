import Foundation

/// Bounds-checked little-endian field access into a `Data` buffer, addressed
/// relative to the buffer's own start (i.e. offset 0 is the first byte of
/// `self`, regardless of `self.startIndex`). Every accessor here adds
/// `self.startIndex` explicitly so these are safe to use on sub-slices of a
/// larger `Data` as well as on freshly-allocated buffers.
extension Data {
    func leU8(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[startIndex + offset]
    }

    func leU16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let b0 = self[startIndex + offset]
        let b1 = self[startIndex + offset + 1]
        return UInt16(b0) | (UInt16(b1) << 8)
    }

    /// Signed little-endian 16-bit read (used by ArtworkDB's `mhni` padding
    /// fields and `mhod` type tag, which libgpod declares as `gint16`).
    func leI16(at offset: Int) -> Int16? {
        leU16(at: offset).map { Int16(bitPattern: $0) }
    }

    func leU32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(self[startIndex + offset + i]) << (8 * i) }
        return v
    }

    func leU64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[startIndex + offset + i]) << (8 * i) }
        return v
    }

    /// IEEE-754 single-precision float stored little-endian (used by mhit's samplerate2).
    func leFloat32(at offset: Int) -> Float? {
        guard let bits = leU32(at: offset) else { return nil }
        return Float(bitPattern: bits)
    }

    mutating func setLE(_ v: UInt8, at offset: Int) {
        precondition(offset >= 0 && offset < count)
        self[startIndex + offset] = v
    }

    mutating func setLE(_ v: UInt16, at offset: Int) {
        precondition(offset >= 0 && offset + 2 <= count)
        self[startIndex + offset] = UInt8(v & 0xff)
        self[startIndex + offset + 1] = UInt8((v >> 8) & 0xff)
    }

    mutating func setLE(_ v: UInt32, at offset: Int) {
        precondition(offset >= 0 && offset + 4 <= count)
        for i in 0..<4 { self[startIndex + offset + i] = UInt8((v >> (8 * i)) & 0xff) }
    }

    mutating func setLE(_ v: UInt64, at offset: Int) {
        precondition(offset >= 0 && offset + 8 <= count)
        for i in 0..<8 { self[startIndex + offset + i] = UInt8((v >> (8 * i)) & 0xff) }
    }

    mutating func setLE(_ v: Float, at offset: Int) {
        setLE(v.bitPattern, at: offset)
    }
}
