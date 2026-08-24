import Foundation
import DAPDevice

/// Pure arithmetic behind the storage bar: how a volume's capacity splits
/// into used / free / incoming (about to be added) / freed (about to be
/// removed) segments, and whether a prospective sync fits.
///
/// Deliberately holds no reference to `DAPVolume` or the filesystem, so it
/// can be constructed and asserted on directly in tests without a device.
public struct StorageBreakdown: Equatable, Sendable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let freeBytes: Int64
    public let incomingBytes: Int64
    public let freedBytes: Int64

    public init(totalBytes: Int64, freeBytes: Int64, incomingBytes: Int64 = 0, freedBytes: Int64 = 0) {
        self.totalBytes = max(0, totalBytes)
        self.freeBytes = max(0, min(freeBytes, totalBytes))
        self.usedBytes = max(0, self.totalBytes - self.freeBytes)
        self.incomingBytes = max(0, incomingBytes)
        self.freedBytes = max(0, freedBytes)
    }

    public init(capacity: DAPVolume.Capacity, incomingBytes: Int64 = 0, freedBytes: Int64 = 0) {
        self.init(
            totalBytes: capacity.totalBytes,
            freeBytes: capacity.availableBytes,
            incomingBytes: incomingBytes,
            freedBytes: freedBytes
        )
    }

    /// Free space remaining after the incoming/freed bytes are applied. Can
    /// go negative when the sync doesn't fit; callers that want a
    /// non-negative display value should clamp separately so a shortfall is
    /// still visible in the raw number if needed.
    public var resultingFreeBytes: Int64 {
        freeBytes + freedBytes - incomingBytes
    }

    /// Whether the incoming bytes fit given the space freed by removals.
    public var fits: Bool {
        resultingFreeBytes >= 0
    }

    /// Fraction (0...1) of `totalBytes` currently used, safe against a
    /// zero-capacity device (returns 0 rather than `NaN`).
    public var usedFraction: Double { fraction(of: usedBytes) }

    /// Fraction (0...1) of `totalBytes` the incoming bytes would occupy,
    /// clamped to what's actually available so the bar never overflows past
    /// 100% even when a sync doesn't fit.
    public var incomingFraction: Double {
        fraction(of: min(incomingBytes, max(0, freeBytes + freedBytes)))
    }

    private func fraction(of value: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(value) / Double(totalBytes)))
    }
}
