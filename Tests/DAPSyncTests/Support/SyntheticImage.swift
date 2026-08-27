import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Generates small images at runtime for artwork tests, rather than
/// committing binary fixtures to the repo — mirrors `SyntheticAudio`'s
/// reasoning for audio.
enum SyntheticImage {
    /// A solid-color JPEG of the given size. Two colors split diagonally
    /// (top-left `topLeftColor`, bottom-right `bottomRightColor`) so tests
    /// can tell orientation apart, not just "some pixel is roughly the right
    /// hue" — a flipped or rotated encode would put the wrong color in the
    /// wrong corner.
    static func makeJPEG(
        width: Int,
        height: Int,
        topLeftColor: (r: UInt8, g: UInt8, b: UInt8) = (255, 0, 0),
        bottomRightColor: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 255)
    ) -> Data {
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        for row in 0..<height {
            for col in 0..<width {
                let isTopLeft = row < height / 2 && col < width / 2
                let color = isTopLeft ? topLeftColor : bottomRightColor
                let offset = row * bytesPerRow + col * 4
                buffer[offset] = color.r
                buffer[offset + 1] = color.g
                buffer[offset + 2] = color.b
                buffer[offset + 3] = 255
            }
        }

        let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let cgImage = context.makeImage()!

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
