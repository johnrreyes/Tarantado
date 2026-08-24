import Foundation
import Testing
@testable import DAPDB

/// The compilation flag (header byte at offset 30) was previously hardcoded to
/// 0 in `MHIT.make`, so tracks detected as compilations could never be marked
/// as such on the device.
struct CompilationFlagTests {
    @Test func compilationFlagSurvivesAWriteReadRoundTrip() throws {
        for value in [true, false] {
            var fields = MHIT.Fields(uniqueID: 42)
            fields.compilation = value

            let chunk = MHIT.make(fields, strings: [.title: "Track"])
            let reparsed = try ChunkTree.parse(ChunkTree.serialize(chunk))
            let mhit = try #require(MHIT(reparsed))

            #expect(mhit.compilation == value)
            #expect(mhit.headerBytesByteAt30 == (value ? 1 : 0))
        }
    }
}

private extension MHIT {
    var headerBytesByteAt30: UInt8 { chunk.headerBytes.leU8(at: 30) ?? 0 }
}
