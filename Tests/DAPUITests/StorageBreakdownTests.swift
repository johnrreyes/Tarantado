import Foundation
import Testing
import DAPDevice
@testable import DAPUI

@Suite struct StorageBreakdownTests {
    @Test func derivesUsedBytesFromTotalAndFree() {
        let breakdown = StorageBreakdown(totalBytes: 1000, freeBytes: 400)
        #expect(breakdown.usedBytes == 600)
        #expect(breakdown.usedFraction == 0.6)
    }

    @Test func clampsNonsensicalInputsRatherThanPropagatingThem() {
        // A FAT32 iPod can report free space larger than capacity, or a
        // capacity of zero — see DAPVolume.capacity's fallback path.
        let overFree = StorageBreakdown(totalBytes: 1000, freeBytes: 5000)
        #expect(overFree.freeBytes == 1000)
        #expect(overFree.usedBytes == 0)

        let negative = StorageBreakdown(totalBytes: -10, freeBytes: -10)
        #expect(negative.totalBytes == 0)
        #expect(negative.freeBytes == 0)
    }

    @Test func zeroCapacityDeviceProducesNoNaNFractions() {
        // volumeAvailableCapacityForImportantUsage returns 0 on FAT32 USB
        // volumes, so a zero-capacity breakdown is a real case, not a
        // hypothetical one. Dividing by it must not reach the view layer.
        let breakdown = StorageBreakdown(totalBytes: 0, freeBytes: 0, incomingBytes: 500)
        #expect(breakdown.usedFraction == 0)
        #expect(breakdown.incomingFraction == 0)
        #expect(breakdown.usedFraction.isNaN == false)
        #expect(breakdown.incomingFraction.isNaN == false)
    }

    @Test func resultingFreeSpaceAccountsForBothIncomingAndFreedBytes() {
        let breakdown = StorageBreakdown(totalBytes: 1000, freeBytes: 100, incomingBytes: 300, freedBytes: 250)
        #expect(breakdown.resultingFreeBytes == 50)
        #expect(breakdown.fits)
    }

    @Test func reportsAShortfallRatherThanClampingItAwayEnabled() {
        let breakdown = StorageBreakdown(totalBytes: 1000, freeBytes: 100, incomingBytes: 400)
        #expect(breakdown.fits == false)
        // The raw number stays negative so a caller can show how far over
        // the sync is, while the bar fraction is still clamped to the bar.
        #expect(breakdown.resultingFreeBytes == -300)
        #expect(breakdown.incomingFraction <= 1)
    }

    @Test func buildsFromAVolumeCapacityDirectly() {
        let capacity = DAPVolume.Capacity(totalBytes: 2000, availableBytes: 800)
        let breakdown = StorageBreakdown(capacity: capacity, incomingBytes: 100)
        #expect(breakdown.totalBytes == 2000)
        #expect(breakdown.usedBytes == 1200)
        #expect(breakdown.incomingBytes == 100)
    }
}
