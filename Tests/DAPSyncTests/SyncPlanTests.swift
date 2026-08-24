import Foundation
import Testing
import DAPDB
import DAPDevice
@testable import DAPSync

@Suite struct SyncPlanTests {
    private func makeSourceTrack(
        url: URL = URL(fileURLWithPath: "/tmp/x.mp3"),
        fileSize: Int64 = 1_000_000,
        title: String = "Title",
        artist: String? = "Artist",
        durationMS: Int = 200_000,
        compatibility: AudioCompatibility = .passThrough(SourceAudioFormat(kind: .mp3, filetypeMarker: 0, filetypeString: "MPEG audio file"))
    ) -> SourceTrack {
        SourceTrack(
            fileURL: url,
            fileSize: fileSize,
            title: title,
            artist: artist,
            durationMS: durationMS,
            compatibility: compatibility
        )
    }

    @Test func matchesTracksIgnoringCasePunctuationAndDiacritics() {
        let device = makeDeviceTrack(uniqueID: 1, title: "Cafe\u{301}, Rock & Roll!", artist: "Beyonce", size: 1_000_000, lengthMS: 200_000)
        let source = makeSourceTrack(fileSize: 1_000_000, title: "cafe   rock roll", artist: "beyoncé", durationMS: 200_000)

        let plan = SyncPlan.compute(deviceTracks: [device], sourceTracks: [source])
        #expect(plan.toAdd.isEmpty)
        #expect(plan.unchanged.map(\.uniqueID) == [1])
    }

    @Test func differentSizeIsNotAMatchEvenWithIdenticalTags() {
        let device = makeDeviceTrack(uniqueID: 1, title: "Title", artist: "Artist", size: 1_000_000, lengthMS: 200_000)
        let source = makeSourceTrack(fileSize: 2_000_000, title: "Title", artist: "Artist", durationMS: 200_000)

        let plan = SyncPlan.compute(deviceTracks: [device], sourceTracks: [source])
        #expect(plan.toAdd.count == 1)
        #expect(plan.unchanged.isEmpty)
    }

    @Test func computeIsIdempotentAcrossRepeatedCalls() {
        let source1 = makeSourceTrack(url: URL(fileURLWithPath: "/tmp/a.mp3"), fileSize: 1_000_000, title: "A", artist: "Art", durationMS: 100_000)
        let source2 = makeSourceTrack(url: URL(fileURLWithPath: "/tmp/b.mp3"), fileSize: 2_000_000, title: "B", artist: "Art", durationMS: 150_000)

        // First "sync": nothing on the device yet.
        let firstPlan = SyncPlan.compute(deviceTracks: [], sourceTracks: [source1, source2])
        #expect(firstPlan.toAdd.count == 2)

        // Simulate what the device would look like after applying that
        // plan (same content, now represented as device Tracks).
        let deviceAfterSync = [
            makeDeviceTrack(uniqueID: 1, title: "A", artist: "Art", size: 1_000_000, lengthMS: 100_000),
            makeDeviceTrack(uniqueID: 2, title: "B", artist: "Art", size: 2_000_000, lengthMS: 150_000),
        ]

        // Second "sync" of the exact same, unchanged source folder must be a no-op.
        let secondPlan = SyncPlan.compute(deviceTracks: deviceAfterSync, sourceTracks: [source1, source2])
        #expect(secondPlan.toAdd.isEmpty)
        #expect(secondPlan.toRemove.isEmpty)
        #expect(secondPlan.unchanged.count == 2)
        #expect(secondPlan.isEmpty) // nothing to add or remove: the sync is idempotent
        #expect(secondPlan.bytesRequired == 0)
    }

    @Test func unsupportedSourceTracksAreSkippedNotAdded() {
        let unsupported = makeSourceTrack(title: "Bad", compatibility: .unsupported(reason: "DRM"))
        let plan = SyncPlan.compute(deviceTracks: [], sourceTracks: [unsupported])
        #expect(plan.toAdd.isEmpty)
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped.first?.reason == "DRM")
    }

    @Test func removeMissingDefaultsToFalseSoUnmatchedDeviceTracksAreLeftAlone() {
        let device = makeDeviceTrack(uniqueID: 1, title: "Untouched", artist: "Artist", size: 1, lengthMS: 1)
        let plan = SyncPlan.compute(deviceTracks: [device], sourceTracks: [])
        #expect(plan.toRemove.isEmpty)
    }

    @Test func removeMissingProposesDeletionOfUnmatchedDeviceTracks() {
        let device = makeDeviceTrack(uniqueID: 1, title: "Gone", artist: "Artist", size: 500, lengthMS: 1)
        let plan = SyncPlan.compute(deviceTracks: [device], sourceTracks: [], selection: SyncSelection(removeMissing: true))
        #expect(plan.toRemove.count == 1)
        #expect(plan.bytesFreed == 500)
    }

    @Test func includedSourceFileURLsLimitsWhichFilesAreConsidered() {
        let a = makeSourceTrack(url: URL(fileURLWithPath: "/tmp/a.mp3"), title: "A")
        let b = makeSourceTrack(url: URL(fileURLWithPath: "/tmp/b.mp3"), title: "B")

        let plan = SyncPlan.compute(
            deviceTracks: [],
            sourceTracks: [a, b],
            selection: SyncSelection(includedSourceFileURLs: [a.fileURL])
        )
        #expect(plan.toAdd.count == 1)
        #expect(plan.toAdd.first?.source.fileURL == a.fileURL)
    }

    @Test func fitsAccountsForBytesFreedByRemovals() {
        var plan = SyncPlan()
        plan.bytesRequired = 1_000
        plan.bytesFreed = 400
        let capacity = DAPVolume.Capacity(totalBytes: 10_000, availableBytes: 700)
        #expect(plan.fits(in: capacity)) // 700 + 400 >= 1000
        plan.bytesFreed = 0
        #expect(!plan.fits(in: capacity)) // 700 >= 1000 is false
    }

    // MARK: - Direct removal

    @Test func removingSelectsExactlyTheRequestedTracksAndLeavesTheRestUnchanged() {
        let a = makeDeviceTrack(uniqueID: 1, title: "A", artist: "X", size: 100)
        let b = makeDeviceTrack(uniqueID: 2, title: "B", artist: "X", size: 250)
        let c = makeDeviceTrack(uniqueID: 3, title: "C", artist: "X", size: 400)

        let (plan, unmatched) = SyncPlan.removing(trackIDs: [1, 3], from: [a, b, c])

        #expect(unmatched.isEmpty)
        #expect(plan.toAdd.isEmpty)
        let removedIDs = plan.toRemove.map(\.deviceTrack.uniqueID)
        let expectedRemoved: [UInt32] = [1, 3]
        #expect(removedIDs == expectedRemoved)
        let unchangedIDs = plan.unchanged.map(\.uniqueID)
        let expectedUnchanged: [UInt32] = [2]
        #expect(unchangedIDs == expectedUnchanged)
        #expect(plan.bytesFreed == 500)
        #expect(plan.bytesRequired == 0)
        #expect(plan.isEmpty == false)
    }

    @Test func removingReportsIDsThatAreNotOnTheDeviceRatherThanSilentlyDoingLess() {
        let a = makeDeviceTrack(uniqueID: 1, title: "A", artist: "X", size: 100)

        let (plan, unmatched) = SyncPlan.removing(trackIDs: [1, 42], from: [a])

        let expectedUnmatched: [UInt32] = [42]
        #expect(unmatched == expectedUnmatched)
        #expect(plan.toRemove.count == 1)
    }

    @Test func removingNothingProducesAnEmptyPlan() {
        let a = makeDeviceTrack(uniqueID: 1, title: "A", artist: "X", size: 100)

        let (plan, unmatched) = SyncPlan.removing(trackIDs: [], from: [a])

        #expect(unmatched.isEmpty)
        #expect(plan.isEmpty)
        #expect(plan.bytesFreed == 0)
    }
}
