import Foundation
import Testing
@testable import DAPSync

@Suite struct ArtworkEncoderTests {
    private func rgb565(_ pixelData: Data, x: Int, y: Int, width: Int) -> UInt16 {
        let offset = (y * width + x) * 2
        let lo = UInt16(pixelData[pixelData.startIndex + offset])
        let hi = UInt16(pixelData[pixelData.startIndex + offset + 1])
        return lo | (hi << 8)
    }

    private func componentsOf565(_ value: UInt16) -> (r: UInt8, g: UInt8, b: UInt8) {
        let r5 = (value >> 11) & 0x1f
        let g6 = (value >> 5) & 0x3f
        let b5 = value & 0x1f
        // Scale back up to 0...255 the same way the 5-6-5 bit widths imply,
        // so a pure red/blue input (255,0,0)/(0,0,255) round-trips exactly.
        return (UInt8(r5 << 3), UInt8(g6 << 2), UInt8(b5 << 3))
    }

    @Test func squareSourceProducesTwoCorrectlySizedFormatsWithNoPadding() throws {
        let jpeg = SyntheticImage.makeJPEG(width: 400, height: 400)
        let thumbnails = try ArtworkEncoder.encode(jpeg)

        #expect(thumbnails.map(\.formatID).sorted() == [1028, 1029])

        let small = try #require(thumbnails.first { $0.formatID == 1028 })
        #expect(small.pixelData.count == 100 * 100 * 2)
        #expect(small.horizontalPadding == 0)
        #expect(small.verticalPadding == 0)
        #expect(small.imageWidth == 100)
        #expect(small.imageHeight == 100)

        let large = try #require(thumbnails.first { $0.formatID == 1029 })
        #expect(large.pixelData.count == 200 * 200 * 2)
        #expect(large.horizontalPadding == 0)
        #expect(large.verticalPadding == 0)
    }

    @Test func orientationIsPreservedNotFlipped() throws {
        // Distinct colors in each corner so a flip/rotation bug shows up as
        // the wrong color in the wrong corner, not just "looks about right".
        let jpeg = SyntheticImage.makeJPEG(
            width: 400, height: 400,
            topLeftColor: (255, 0, 0),
            bottomRightColor: (0, 0, 255)
        )
        let thumbnails = try ArtworkEncoder.encode(jpeg, formats: [ArtworkEncoder.Format(formatID: 1029, width: 200, height: 200)])
        let thumbnail = try #require(thumbnails.first)

        let topLeft = componentsOf565(rgb565(thumbnail.pixelData, x: 10, y: 10, width: 200))
        #expect(topLeft.r > 200 && topLeft.b < 20, "expected red near the top-left corner, got \(topLeft)")

        let bottomRight = componentsOf565(rgb565(thumbnail.pixelData, x: 190, y: 190, width: 200))
        #expect(bottomRight.b > 200 && bottomRight.r < 20, "expected blue near the bottom-right corner, got \(bottomRight)")
    }

    @Test func nonSquareSourceIsLetterboxedNotCropped() throws {
        // A wide source scaled into a square target: full width, black bars
        // top and bottom -- never cropped, matching every 5G cover-art
        // format's `crop == false`.
        let jpeg = SyntheticImage.makeJPEG(width: 400, height: 200)
        let thumbnails = try ArtworkEncoder.encode(jpeg, formats: [ArtworkEncoder.Format(formatID: 1029, width: 200, height: 200)])
        let thumbnail = try #require(thumbnails.first)

        #expect(thumbnail.pixelData.count == 200 * 200 * 2) // full canvas, always
        #expect(thumbnail.horizontalPadding == 0)
        #expect(thumbnail.verticalPadding == 50) // (200 - 100) / 2

        // A corner of the letterbox bar must be black, not the source content.
        let barPixel = componentsOf565(rgb565(thumbnail.pixelData, x: 5, y: 5, width: 200))
        #expect(barPixel == (0, 0, 0))
    }

    @Test func undecodableDataThrows() {
        #expect(throws: ArtworkEncoder.EncodingError.undecodableImage) {
            _ = try ArtworkEncoder.encode(Data([0x00, 0x01, 0x02]))
        }
    }
}
