import Foundation
import Testing
import DAPDB
import DAPSync
@testable import DAPUI

@Suite struct SyncOverallProgressTests {
    // Plans are built through SyncPlan's real constructors rather than by
    // assembling items directly, so these exercise the same shapes the app
    // actually produces.

    private func sourceTrack(bytes: Int64, name: String) -> SourceTrack {
        SourceTrack(
            fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
            fileSize: bytes,
            title: name,
            artist: "Artist",
            durationMS: 1000,
            compatibility: .passThrough(SourceAudioFormat(kind: .mp3, filetypeMarker: 0, filetypeString: "MPEG audio file"))
        )
    }

    private func addPlan(_ sizes: [Int64]) -> SyncPlan {
        let sources = sizes.enumerated().map { sourceTrack(bytes: $0.element, name: "t\($0.offset).mp3") }
        return SyncPlan.compute(deviceTracks: [], sourceTracks: sources)
    }

    private func removalPlan(count: Int) -> SyncPlan {
        let tracks = (1...count).map { makeUITestTrack(uniqueID: UInt32($0), size: 500) }
        return SyncPlan.removing(trackIDs: tracks.map(\.uniqueID), from: tracks).plan
    }

    @Test func countsEarlierFilesPlusTheCurrentFilesProgress() {
        let plan = addPlan([100, 200, 300])
        // Halfway through the second file: 100 done, plus 100 of its 200.
        let progress = SyncProgress(phase: .copying(fileIndex: 1, totalFiles: 3), bytesCopied: 100, bytesTotal: 200)
        let overall = SyncOverallProgress(plan: plan, progress: progress)

        #expect(overall.bytesDone == 200)
        #expect(overall.bytesTotal == 600)
        #expect(overall.unitsDone == 1)
        #expect(overall.unitsTotal == 3)
        #expect(abs(overall.fraction - 1.0 / 3.0) < 0.0001)
    }

    @Test func readsZeroBeforeCopyingStarts() {
        let plan = addPlan([100, 200])
        for phase in [SyncProgress.Phase.backingUp, .parsingDatabase] {
            let overall = SyncOverallProgress(plan: plan, progress: SyncProgress(phase: phase))
            #expect(overall.bytesDone == 0)
            #expect(overall.fraction == 0)
        }
    }

    @Test func readsCompleteOnceTheDatabaseIsBeingWritten() {
        let plan = addPlan([100, 200])
        let overall = SyncOverallProgress(plan: plan, progress: SyncProgress(phase: .writingDatabase))
        #expect(overall.bytesDone == 300)
        #expect(overall.fraction == 1)
        #expect(overall.unitsDone == overall.unitsTotal)
    }

    @Test func aRemovalOnlySyncAdvancesByFileCountRatherThanSittingAtZero() {
        // Nothing is copied, so a bytes-only fraction would never move off 0
        // for the entire sync.
        let plan = removalPlan(count: 2)
        let midway = SyncOverallProgress(plan: plan, progress: SyncProgress(phase: .removing(fileIndex: 1, totalFiles: 2)))

        #expect(midway.bytesTotal == 0)
        #expect(midway.unitsDone == 1)
        #expect(midway.unitsTotal == 2)
        #expect(midway.fraction == 0.5)
    }

    @Test func copiesAreAllCountedDoneOnceRemovalsBegin() {
        // A mirror sync: one track added, one stale device track removed.
        let existing = makeUITestTrack(uniqueID: 99, size: 50)
        let plan = SyncPlan.compute(
            deviceTracks: [existing],
            sourceTracks: [sourceTrack(bytes: 400, name: "new.mp3")],
            selection: SyncSelection(removeMissing: true)
        )
        #expect(plan.toAdd.count == 1)
        #expect(plan.toRemove.count == 1)

        let overall = SyncOverallProgress(plan: plan, progress: SyncProgress(phase: .removing(fileIndex: 0, totalFiles: 1)))
        #expect(overall.bytesDone == 400)
        #expect(overall.unitsDone == 1)
        #expect(overall.unitsTotal == 2)
    }

    @Test func clampsWhenAFileGrewBetweenScanAndCopy() {
        let plan = addPlan([100])
        // The engine reports more bytes than the plan measured.
        let progress = SyncProgress(phase: .copying(fileIndex: 0, totalFiles: 1), bytesCopied: 5000, bytesTotal: 5000)
        let overall = SyncOverallProgress(plan: plan, progress: progress)
        #expect(overall.bytesDone == 100)
        #expect(overall.fraction == 1)
    }

    @Test func anEmptyPlanReportsNoProgressRatherThanNaN() {
        let overall = SyncOverallProgress(plan: SyncPlan(), progress: SyncProgress(phase: .writingDatabase))
        #expect(overall.fraction == 0)
        #expect(overall.fraction.isNaN == false)
    }
}

/// `Track` has no public memberwise init; build one through `MHIT.make`.
func makeUITestTrack(uniqueID: UInt32, size: UInt32) -> Track {
    var fields = MHIT.Fields(uniqueID: uniqueID)
    fields.size = size
    let chunk = MHIT.make(fields, strings: [:])
    guard let mhit = MHIT(chunk) else { preconditionFailure("MHIT.make produced a non-mhit chunk") }
    return Track(from: mhit)
}
