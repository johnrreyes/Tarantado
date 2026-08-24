import Foundation
@testable import DAPSync

/// A tiny thread-safe box for collecting progress callbacks in tests. The
/// engine/scanner progress closures are `@Sendable`, so a plain captured
/// `var` isn't allowed under strict concurrency; this uses a lock instead of
/// spinning up actor-hop overhead for what's always a synchronous,
/// same-task sequence of calls in these tests.
final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [LibraryScanner.Progress] = []

    func add(_ progress: LibraryScanner.Progress) {
        lock.lock()
        defer { lock.unlock() }
        updates.append(progress)
    }

    func snapshot() -> [LibraryScanner.Progress] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}
