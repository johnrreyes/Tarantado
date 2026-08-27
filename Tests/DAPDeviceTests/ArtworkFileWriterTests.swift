import Foundation
import Testing
@testable import DAPDevice

@Suite struct ArtworkFileWriterTests {
    @Test func appendsSequentiallyAndReportsCorrectOffsets() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)
        let writer = ArtworkFileWriter(volume: volume)

        let first = try await writer.append(formatID: 1029, pixelData: Data(repeating: 0xAA, count: 100))
        #expect(first.filename == "F1029_1.ithmb")
        #expect(first.offset == 0)

        let second = try await writer.append(formatID: 1029, pixelData: Data(repeating: 0xBB, count: 50))
        #expect(second.filename == "F1029_1.ithmb")
        #expect(second.offset == 100)

        let fileURL = volume.artworkDirectory.appendingPathComponent("F1029_1.ithmb")
        let contents = try Data(contentsOf: fileURL)
        #expect(contents.count == 150)
        #expect(contents[contents.startIndex] == 0xAA)
        #expect(contents[contents.startIndex + 100] == 0xBB)
    }

    @Test func differentFormatsGetIndependentFilesAndOffsets() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)
        let writer = ArtworkFileWriter(volume: volume)

        let small = try await writer.append(formatID: 1028, pixelData: Data(repeating: 1, count: 20_000))
        let large = try await writer.append(formatID: 1029, pixelData: Data(repeating: 2, count: 80_000))

        #expect(small.filename == "F1028_1.ithmb")
        #expect(large.filename == "F1029_1.ithmb")
        #expect(small.offset == 0)
        #expect(large.offset == 0)
    }

    @Test func rollsOverToANewFileOnceTheCurrentOneWouldExceedTheBudget() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)
        let writer = ArtworkFileWriter(volume: volume, maxFileSize: 100)

        let first = try await writer.append(formatID: 1029, pixelData: Data(repeating: 1, count: 60))
        #expect(first.filename == "F1029_1.ithmb")
        #expect(first.offset == 0)

        // 60 + 60 > 100, so this must roll to a fresh file rather than
        // overflow the first one.
        let second = try await writer.append(formatID: 1029, pixelData: Data(repeating: 2, count: 60))
        #expect(second.filename == "F1029_2.ithmb")
        #expect(second.offset == 0)

        let firstFile = try Data(contentsOf: volume.artworkDirectory.appendingPathComponent("F1029_1.ithmb"))
        #expect(firstFile.count == 60)
        let secondFile = try Data(contentsOf: volume.artworkDirectory.appendingPathComponent("F1029_2.ithmb"))
        #expect(secondFile.count == 60)
    }

    @Test func resumesFromAnExistingFilesCurrentSizeRatherThanOverwriting() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)

        // Simulate a prior sync: an F1029_1.ithmb already on disk with some
        // bytes in it, written by a writer this test doesn't share state
        // with -- a fresh ArtworkFileWriter must still pick up where it left
        // off, seeded purely from what's on disk.
        try FileManager.default.createDirectory(at: volume.artworkDirectory, withIntermediateDirectories: true)
        let existingURL = volume.artworkDirectory.appendingPathComponent("F1029_1.ithmb")
        try Data(repeating: 0xFF, count: 1_000).write(to: existingURL)

        let writer = ArtworkFileWriter(volume: volume)
        let written = try await writer.append(formatID: 1029, pixelData: Data(repeating: 0x11, count: 10))
        #expect(written.filename == "F1029_1.ithmb")
        #expect(written.offset == 1_000)

        let contents = try Data(contentsOf: existingURL)
        #expect(contents.count == 1_010)
    }

    @Test func aPayloadLargerThanTheBudgetIsRejectedRatherThanSilentlyWritten() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)
        let writer = ArtworkFileWriter(volume: volume, maxFileSize: 50)

        await #expect(throws: ArtworkFileWriter.WriteError.self) {
            _ = try await writer.append(formatID: 1029, pixelData: Data(repeating: 1, count: 51))
        }
    }
}
