import Foundation
import Testing
@testable import DAPDB

/// A parse failure on a device the developer doesn't own is only ever as
/// useful as its error message. A TestFlight user on a 5G iPod Video hit
/// `malformedChunk` and saw "The operation couldn't be completed.
/// (DAPDB.DAPDBError error 2.)" — the bridged NSError form, which throws away
/// the tag and offset the error had already computed. These tests pin the
/// message down so that regression can't come back.
struct ChunkParseDiagnosticsTests {
    /// Corrupts the golden fixture at `offset` by writing `value` as a
    /// little-endian UInt32, then returns the damaged bytes.
    private func corruptedGolden(at offset: Int, to value: UInt32) throws -> Data {
        var data = try GoldenFixture.data()
        for i in 0..<4 {
            data[data.startIndex + offset + i] = UInt8((value >> (8 * i)) & 0xff)
        }
        return data
    }

    @Test func parseFailureIsLocalizedRatherThanARawNSErrorCode() throws {
        // mhbd's totalLen (offset 8) set below its headerLen (244) -> malformedChunk,
        // the case that bridges to "DAPDBError error 2".
        let data = try corruptedGolden(at: 8, to: 16)

        let failure: ChunkParseFailure
        do {
            _ = try ChunkTree.parse(data)
            Issue.record("Expected a parse failure")
            return
        } catch let error as ChunkParseFailure {
            failure = error
        }

        let message = try #require(failure.errorDescription)
        // The exact string a user would previously have seen must not appear.
        #expect(!message.contains("DAPDBError error"))
        #expect(!message.contains("The operation couldn't be completed"))
        // localizedDescription is what the UI actually renders, and for a
        // LocalizedError it must route to errorDescription.
        #expect((failure as Error).localizedDescription == message)
    }

    @Test func parseFailureNamesTheChunkOffsetAndBytes() throws {
        let data = try corruptedGolden(at: 8, to: 16)

        do {
            _ = try ChunkTree.parse(data)
            Issue.record("Expected a parse failure")
            return
        } catch let failure as ChunkParseFailure {
            #expect(failure.offset == 0)
            #expect(failure.path.contains("mhbd"))
            // "6d 68 62 64" is "mhbd" — the hex window makes a screenshot
            // sufficient to identify the chunk.
            #expect(failure.nearbyBytes.hasPrefix("6d 68 62 64"))
            if case .malformedChunk(let detail) = failure.underlying {
                #expect(detail.contains("totalLen 16"))
                #expect(detail.contains("headerLen 244"))
            } else {
                Issue.record("Expected malformedChunk, got \(failure.underlying)")
            }
        }
    }

    @Test func failureDeepInTheTreeReportsItsAncestorPath() throws {
        // The mhlt (track list) sits at offset 528 in the fixture; break the
        // totalLen of the mhsd that contains it (that mhsd starts at 432).
        let data = try GoldenFixture.data()
        let mhsdOffset = 432
        #expect(Array(data[mhsdOffset..<mhsdOffset + 4]) == Array("mhsd".utf8))

        let broken = try corruptedGolden(at: mhsdOffset + 4, to: 4) // headerLen 4 < 8

        do {
            _ = try ChunkTree.parse(broken)
            Issue.record("Expected a parse failure")
            return
        } catch let failure as ChunkParseFailure {
            #expect(failure.offset == mhsdOffset)
            // Ancestors first, failing chunk last.
            #expect(failure.path.contains("mhbd@0"))
            #expect(failure.path.contains("mhsd@\(mhsdOffset)"))
        }
    }

    /// The counted lists (mhlt/mhlp/mhla) carry no extent of their own, so a
    /// count that disagrees with the bytes that follow used to send the parser
    /// walking into arbitrary data and fail somewhere unrelated. It must now
    /// blame the list itself.
    @Test func countedListWithTooManyChildrenBlamesTheList() throws {
        // The fixture's mhlt (track list) is at 528 with count 0, and its
        // children would begin at 620. Claim one child, and make the bytes
        // there not a chunk.
        let mhltOffset = 528
        let childOffset = 620
        var data = try corruptedGolden(at: mhltOffset + 8, to: 1)
        #expect(Array(data[mhltOffset..<mhltOffset + 4]) == Array("mhlt".utf8))
        for i in 0..<4 { data[data.startIndex + childOffset + i] = 0x00 }

        do {
            _ = try ChunkTree.parse(data)
            Issue.record("Expected a parse failure")
            return
        } catch let failure as ChunkParseFailure {
            #expect(failure.path.contains("mhlt@\(mhltOffset)"))
            #expect(failure.offset == childOffset)
            if case .malformedChunk(let detail) = failure.underlying {
                #expect(detail.contains("declares 1 child chunk(s)"))
                #expect(detail.contains("0x00000000"))
            } else {
                Issue.record("Expected malformedChunk, got \(failure.underlying)")
            }
        }
    }

    @Test func aGarbageTagIsShownAsHexNotReplacementCharacters() throws {
        var data = try GoldenFixture.data()
        // Blank the root tag so the "tag" is non-printable.
        for i in 0..<4 { data[data.startIndex + i] = 0x00 }
        // ...and break headerLen so parsing actually stops here.
        data[data.startIndex + 4] = 0x01

        do {
            _ = try ChunkTree.parse(data)
            Issue.record("Expected a parse failure")
            return
        } catch let failure as ChunkParseFailure {
            #expect(failure.path.contains("0x00000000"))
            #expect(!failure.path.contains("\u{FFFD}"))
        }
    }

    @Test func anEmptyDatabaseFailsWithAReadableMessage() throws {
        do {
            _ = try ChunkTree.parse(Data())
            Issue.record("Expected a parse failure")
            return
        } catch let failure as ChunkParseFailure {
            let message = try #require(failure.errorDescription)
            #expect(message.contains("truncated") || message.contains("ends unexpectedly"))
        }
    }

    @Test func theGoldenFixtureStillParsesUnchanged() throws {
        let data = try GoldenFixture.data()
        let root = try ChunkTree.parse(data)
        #expect(ChunkTree.serialize(root) == data)
    }
}
