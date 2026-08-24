import Foundation
import DAPSync

/// How far through the *whole* sync we are, as opposed to how far through
/// the current file — `SyncProgress` only reports the latter.
///
/// Derived by combining the plan (which knows every file's size up front)
/// with the engine's current phase, so it needs no extra bookkeeping in the
/// engine: the bytes already transferred are the sizes of the files before
/// the current one, plus the current file's progress.
///
/// Pure arithmetic over two values, so the awkward cases — a plan that is
/// pure removals, a zero-byte plan, a phase before copying has started —
/// are asserted directly in tests rather than eyeballed in a running app.
struct SyncOverallProgress: Equatable {
    let bytesDone: Int64
    let bytesTotal: Int64
    /// Files fully finished, counting both copies and removals.
    let unitsDone: Int
    /// Total files the sync will touch: everything added plus everything removed.
    let unitsTotal: Int

    init(plan: SyncPlan, progress: SyncProgress) {
        let addSizes = plan.toAdd.map(\.source.fileSize)
        bytesTotal = plan.bytesRequired

        switch progress.phase {
        case .backingUp, .parsingDatabase:
            bytesDone = 0
            unitsDone = 0

        case .copying(let fileIndex, _):
            let completed = addSizes.prefix(max(0, fileIndex)).reduce(Int64(0), +)
            // Clamped because the engine reports a file's own progress, and
            // a source file can grow between the scan that measured it and
            // the copy that reads it.
            bytesDone = min(bytesTotal, completed + max(0, progress.bytesCopied))
            unitsDone = max(0, fileIndex)

        case .removing(let fileIndex, _):
            // Every copy is finished by the time removals start.
            bytesDone = bytesTotal
            unitsDone = plan.toAdd.count + max(0, fileIndex)

        case .writingDatabase:
            bytesDone = bytesTotal
            unitsDone = plan.toAdd.count + plan.toRemove.count
        }

        unitsTotal = plan.toAdd.count + plan.toRemove.count
    }

    /// 0...1. Falls back to counting files when the plan moves no bytes at
    /// all — a removal-only sync would otherwise sit at 0% throughout.
    var fraction: Double {
        if bytesTotal > 0 {
            return min(1, max(0, Double(bytesDone) / Double(bytesTotal)))
        }
        guard unitsTotal > 0 else { return 0 }
        return min(1, max(0, Double(unitsDone) / Double(unitsTotal)))
    }
}
