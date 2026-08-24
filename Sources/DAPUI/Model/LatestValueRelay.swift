import Foundation

/// Delivers the most recent value it was handed to the main actor, dropping
/// any that were superseded before they could be shown.
///
/// The copy loop reports progress after every 1 MiB chunk, which on flash
/// storage means a callback every few milliseconds — far faster than the
/// screen redraws. Hopping to the main actor once per callback creates two
/// problems, and the second is the one that actually corrupts the display:
///
/// 1. It floods the main actor with thousands of one-line tasks.
/// 2. Unstructured `Task`s carry **no ordering guarantee** relative to each
///    other, so a stale progress value can land after a newer one. A bar fed
///    that way jumps around, and whichever value happens to arrive last is
///    the one left on screen — typically a file's final "complete" reading,
///    which is why the per-file bar reads 100% no matter what is happening.
///
/// So callers only ever overwrite a shared slot, and at most one delivery is
/// ever in flight. Reading the slot and delivering it both happen inside a
/// single synchronous main-actor step, so a delivery can never be overtaken:
/// a later hop always observes an empty slot rather than an older value.
final class LatestValueRelay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Value?
    private var isDelivering = false
    private let deliver: @MainActor @Sendable (Value) -> Void

    init(deliver: @escaping @MainActor @Sendable (Value) -> Void) {
        self.deliver = deliver
    }

    /// Records `value` as the newest, scheduling a delivery unless one is
    /// already pending. Safe to call from any thread.
    func send(_ value: Value) {
        lock.lock()
        latest = value
        if isDelivering {
            lock.unlock()
            return
        }
        isDelivering = true
        lock.unlock()

        Task { @MainActor in self.drain() }
    }

    @MainActor
    private func drain() {
        lock.lock()
        let value = latest
        latest = nil
        isDelivering = false
        lock.unlock()

        if let value { deliver(value) }
    }
}
