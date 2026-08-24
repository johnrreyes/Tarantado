import Foundation
import Testing
@testable import DAPDB

struct MacEpochTests {
    @Test func zeroIsNil() {
        #expect(MacEpoch.date(fromRaw: 0) == nil)
        #expect(MacEpoch.raw(from: nil) == 0)
    }

    @Test func knownEpochConversion() throws {
        // 2001-01-01 00:00:00 UTC is exactly 3,061,152,000 seconds after
        // the 1904-01-01 Mac epoch (97 years, including 24 leap days).
        let raw: UInt32 = 3_061_152_000
        let date = try #require(MacEpoch.date(fromRaw: raw))
        let expected = Date(timeIntervalSince1970: 978_307_200) // 2001-01-01 UTC in Unix time
        #expect(abs(date.timeIntervalSince1970 - expected.timeIntervalSince1970) < 1)
    }

    @Test func roundTripsThroughDate() {
        let original: UInt32 = 3_500_000_000
        let date = MacEpoch.date(fromRaw: original)
        let back = MacEpoch.raw(from: date)
        #expect(back == original)
    }
}
