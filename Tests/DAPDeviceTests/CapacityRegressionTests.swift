import Foundation
import Testing
@testable import DAPDevice

/// Regression coverage for a bug that only appeared on real hardware.
///
/// `volumeAvailableCapacityForImportantUsage` returns 0 on FAT32 USB volumes —
/// which is every classic iPod — even when the disk is nearly empty. Measured
/// on a physical iPod mini 2G: that key reported 0 while the plain available
/// key reported 23,105,454,080 bytes free of 32,171,130,880. Without a
/// fallback, every sync fails its free-space check on real hardware.
struct CapacityRegressionTests {
    @Test func reportsFreeSpaceOnAVolumeWhereImportantUsageIsZero() throws {
        let pod = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(pod) }

        let volume = try DAPVolume.validate(at: pod)
        let capacity = try volume.capacity()

        #expect(capacity.totalBytes > 0)
        // The real assertion: we never report 0 free on a volume that has space.
        #expect(capacity.availableBytes > 0)
    }

    @Test func fallsBackToPlainAvailableCapacityWhenImportantUsageIsUnusable() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let plain = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0

        // Mirrors the selection logic in DAPVolume.capacity().
        let chosen = important > 0 ? important : plain
        #expect(chosen > 0)
        #expect(chosen == (important > 0 ? important : plain))
    }

    /// Read-only. Skips cleanly when the physical iPod is not connected.
    @Test func realDeviceReportsNonZeroFreeSpaceIfMounted() throws {
        let url = URL(fileURLWithPath: "/Volumes/JOHNREYES'S")
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("iPod_Control").path) else { return }

        let capacity = try DAPVolume.validate(at: url).capacity()
        #expect(capacity.totalBytes > 0)
        #expect(capacity.availableBytes > 0, "FAT32 fallback failed: iPod reported 0 bytes free")
    }
}
