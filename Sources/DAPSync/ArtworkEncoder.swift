import Foundation
import CoreGraphics
import ImageIO

/// Decodes an embedded cover-art image (e.g. an ID3 `APIC` JPEG) and encodes
/// it into the raw RGB565LE thumbnail formats a classic click-wheel iPod's
/// firmware reads from `.ithmb` files.
///
/// This is pure `CoreGraphics`/`ImageIO` — no device I/O, no knowledge of
/// `ArtworkDB`'s chunk layout (see `DAPDB`'s `MHII`/`MHNI` for that). It
/// lives in `DAPSync` rather than `DAPDB` because `DAPDB` is deliberately
/// "pure Foundation" (see `Package.swift`'s target comments); image decoding
/// needs the frameworks `DAPSync` already depends on for `AVFoundation`.
public enum ArtworkEncoder {
    /// One thumbnail rendition a device format table asks for. Field names
    /// and the two iPod 5G/5.5G values below are cross-checked against
    /// libgpod's `ipod_video_cover_art_info` in `itdb_device.c`, and
    /// independently corroborated by iOpenPod's `device/artwork_presets.py`.
    public struct Format: Sendable, Equatable {
        public let formatID: UInt32
        public let width: Int
        public let height: Int

        public init(formatID: UInt32, width: Int, height: Int) {
            self.formatID = formatID
            self.width = width
            self.height = height
        }
    }

    /// iPod 5G/5.5G's two cover-art thumbnail formats: a 100×100 "Now
    /// Playing" thumbnail and a 200×200 larger cover view. Both RGB565,
    /// little-endian, no row padding/alignment, no cropping (see
    /// `EncodedThumbnail`'s doc on what "no cropping" means for non-square
    /// source art).
    public static let ipod5GFormats: [Format] = [
        Format(formatID: 1028, width: 100, height: 100),
        Format(formatID: 1029, width: 200, height: 200),
    ]

    /// One encoded thumbnail, ready to append to its format's `.ithmb` file
    /// and describe in an `MHNI`.
    public struct EncodedThumbnail: Sendable, Equatable {
        public let formatID: UInt32
        /// Raw RGB565LE pixel bytes, top row first, left-to-right — always
        /// exactly `format.width * format.height * 2` bytes (the full target
        /// canvas), regardless of the source image's aspect ratio.
        public let pixelData: Data

        /// Padding-inclusive dimensions, matching what libgpod's
        /// `ithumb-writer.c::ithumb_writer_write_thumbnail` computes for
        /// `mhni.imageWidth/imageHeight`. For a source aspect ratio that
        /// doesn't match the target square, this is **not** simply the
        /// format's declared width/height — it's `padding + scaledDimension`
        /// (only one side's padding, by construction of the real writer this
        /// mirrors), asymmetric as that looks. Faithfully reproduced rather
        /// than "fixed", since real iPod firmware is what has to agree with
        /// these bytes, not this library's sense of tidiness.
        public let imageWidth: UInt16
        public let imageHeight: UInt16
        public let horizontalPadding: Int16
        public let verticalPadding: Int16
    }

    public enum EncodingError: Error, LocalizedError, Equatable {
        case undecodableImage
        case rasterizationFailed

        public var errorDescription: String? {
            switch self {
            case .undecodableImage:
                return "The embedded artwork could not be decoded as an image."
            case .rasterizationFailed:
                return "Could not rasterize the artwork into a thumbnail bitmap."
            }
        }
    }

    /// Decodes `imageData` and encodes it into every format in `formats`.
    ///
    /// Scales to fit (never crops) and centers within each target canvas,
    /// padding any remainder with black — matching
    /// `ithumb_writer_scale_and_crop`'s `crop == false` branch, the mode
    /// every iPod 5G cover-art format uses. Deliberately does not apply EXIF
    /// orientation correction: that's a camera-photo concern, and embedded
    /// album art doesn't carry rotated EXIF in practice.
    public static func encode(_ imageData: Data, formats: [Format] = ipod5GFormats) throws -> [EncodedThumbnail] {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cgImage.width > 0, cgImage.height > 0 else {
            throw EncodingError.undecodableImage
        }
        return try formats.map { try encodeOne(cgImage, format: $0) }
    }

    private static func encodeOne(_ cgImage: CGImage, format: Format) throws -> EncodedThumbnail {
        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height

        // Scale-to-fit, matching `ithumb_writer_scale_and_crop`'s !crop
        // branch in ithumb-writer.c exactly (including its ceil() rounding).
        let widthScale = Double(format.width) / Double(sourceWidth)
        let heightScale = Double(format.height) / Double(sourceHeight)
        let scaledWidth: Int
        let scaledHeight: Int
        if widthScale < heightScale {
            scaledWidth = format.width
            scaledHeight = min(Int((Double(sourceHeight) * widthScale).rounded(.up)), format.height)
        } else if widthScale > heightScale {
            scaledWidth = min(Int((Double(sourceWidth) * heightScale).rounded(.up)), format.width)
            scaledHeight = format.height
        } else {
            scaledWidth = format.width
            scaledHeight = format.height
        }

        let horizontalPadding = (format.width - scaledWidth) / 2
        let verticalPadding = (format.height - scaledHeight) / 2

        let bytesPerRow = format.width * 4
        var rgbaBuffer = [UInt8](repeating: 0, count: bytesPerRow * format.height)

        guard let context = CGContext(
            data: &rgbaBuffer,
            width: format.width,
            height: format.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw EncodingError.rasterizationFailed
        }

        // Black background (the `back_color` every 5G cover-art format entry
        // leaves at its zeroed default). No coordinate flip needed here:
        // `CGContext.draw(_:in:)` already places a `CGImage`'s row 0 (its
        // top) so that reading `data` back row-major gives row 0 = the
        // image's top — confirmed by `ArtworkEncoderTests
        // .orientationIsPreservedNotFlipped`, which an earlier flip-transform
        // attempt here failed (it double-flipped the result).
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: format.width, height: format.height))

        context.draw(cgImage, in: CGRect(x: horizontalPadding, y: verticalPadding, width: scaledWidth, height: scaledHeight))

        let pixelData = packRGB565LE(rgbaBuffer, width: format.width, height: format.height, bytesPerRow: bytesPerRow)

        return EncodedThumbnail(
            formatID: format.formatID,
            pixelData: pixelData,
            imageWidth: UInt16(clamping: horizontalPadding + scaledWidth),
            imageHeight: UInt16(clamping: verticalPadding + scaledHeight),
            horizontalPadding: Int16(clamping: horizontalPadding),
            verticalPadding: Int16(clamping: verticalPadding)
        )
    }

    /// Packs top-down RGBA8 (alpha ignored) pixels into RGB565, little-endian
    /// — the standard 5-6-5 bit shift `get_RGB_565_pixel` in
    /// `ithumb-writer.c` uses, byte-order matching `THUMB_FORMAT_RGB565_LE`.
    private static func packRGB565LE(_ rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(width * height * 2)
        for row in 0..<height {
            let rowStart = row * bytesPerRow
            for col in 0..<width {
                let pixelStart = rowStart + col * 4
                let r = rgba[pixelStart]
                let g = rgba[pixelStart + 1]
                let b = rgba[pixelStart + 2]
                let value = (UInt16(r >> 3) << 11) | (UInt16(g >> 2) << 5) | UInt16(b >> 3)
                out.append(UInt8(value & 0xff))
                out.append(UInt8((value >> 8) & 0xff))
            }
        }
        return Data(out)
    }
}
