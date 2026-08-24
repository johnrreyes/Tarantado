import Foundation
import Testing
@testable import DAPUI

@Suite struct LatestValueRelayTests {
    /// A flood of values must never leave an *older* one on screen. This is
    /// the failure the per-file progress bar showed on device: values raced
    /// to the main actor out of order, so whichever landed last won.
    @MainActor
    @Test func deliversTheNewestValueAfterAFlood() async throws {
        let received = Received()
        let relay = LatestValueRelay<Int> { value in received.append(value) }

        // Send from a background thread, the way the copy loop does.
        await Task.detached {
            for value in 1...5_000 { relay.send(value) }
        }.value

        // Let every scheduled delivery run.
        while received.values.last != 5_000 {
            await Task.yield()
        }

        let values = received.values
        #expect(values.last == 5_000)
        #expect(values == values.sorted())
        // Coalescing is the point: far fewer deliveries than sends.
        #expect(values.count < 5_000)
    }

    @MainActor
    @Test func deliversASingleValue() async throws {
        let received = Received()
        let relay = LatestValueRelay<Int> { value in received.append(value) }
        relay.send(42)

        while received.values.isEmpty {
            await Task.yield()
        }
        #expect(received.values == [42])
    }

    @MainActor
    private final class Received {
        private(set) var values: [Int] = []
        func append(_ value: Int) { values.append(value) }
    }
}
