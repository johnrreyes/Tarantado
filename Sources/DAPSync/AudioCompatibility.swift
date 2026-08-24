import Foundation
import AVFoundation
import CoreMedia
import DAPDevice

/// The audio codecs a classic click-wheel iPod's firmware can actually
/// decode. AAC and ALAC both live inside an `.m4a`/MPEG-4 container, so the
/// container extension alone can't tell them apart — only the codec inside
/// the file can.
public enum AudioFormatKind: String, Sendable, Equatable, CaseIterable {
    case mp3
    case aac
    case alac
    case aiff
    case wav
}

/// Everything the sync engine needs to write a passthrough-compatible file
/// into the iTunesDB: which codec family it is, plus the two four-character
/// values the database format wants (a numeric "filetype marker" in the
/// `mhit` header, and a human-readable string carried in a child `mhod`).
///
/// The exact bytes iPod firmware expects in the numeric marker are not
/// independently verified against real hardware or against libgpod source in
/// this repo — see the values below and the note in the module's report.
public struct SourceAudioFormat: Sendable, Equatable {
    public let kind: AudioFormatKind
    public let filetypeMarker: UInt32
    public let filetypeString: String

    public init(kind: AudioFormatKind, filetypeMarker: UInt32, filetypeString: String) {
        self.kind = kind
        self.filetypeMarker = filetypeMarker
        self.filetypeString = filetypeString
    }
}

/// The result of classifying one source file for a given device.
public enum AudioCompatibility: Sendable, Equatable {
    /// The file can be copied to the device byte-for-byte; no transcoding needed.
    case passThrough(SourceAudioFormat)
    /// The file cannot be played by classic iPod firmware, or is otherwise unusable.
    case unsupported(reason: String)
}

/// Classifies source audio files by actually inspecting their contents
/// (via `AVURLAsset`), not just their extension — a `.m4a` may hold AAC,
/// ALAC, or FairPlay-protected (DRM) audio, and only opening the file can
/// tell them apart.
public enum AudioCompatibilityChecker {
    /// FAT32 cannot address a file whose size doesn't fit in the 32-bit byte
    /// count its directory entries use, so the format's hard ceiling is
    /// exactly `2^32 - 1` bytes (one byte under 4 GB) — not "4 GB" itself.
    /// Real audio files on an iPod are always vastly smaller than this; the
    /// check exists purely as a hard safety net against something absurd
    /// (e.g. a misidentified video file) rather than as a realistic limit.
    public static let fat32MaxFileSize: Int64 = 4_294_967_295

    /// Classifies `fileURL` for `model`. `model` is accepted for future
    /// per-model refinement (e.g. a device family that can't play ALAC), but
    /// every classic click-wheel iPod supports the same five audio codecs
    /// listed in `AudioFormatKind`, so it is currently unused beyond that.
    public static func classify(fileURL: URL, fileSize: Int64, model: DeviceModel) async -> AudioCompatibility {
        if fileSize >= fat32MaxFileSize {
            return .unsupported(reason: "File is \(fileSize) bytes, at or above the FAT32 file-size limit (4 GB).")
        }
        guard fileSize > 0 else {
            return .unsupported(reason: "File is empty.")
        }

        let asset = AVURLAsset(url: fileURL)

        let hasProtectedContent: Bool
        do {
            hasProtectedContent = try await asset.load(.hasProtectedContent)
        } catch {
            return .unsupported(reason: "Could not open file: \(error.localizedDescription)")
        }
        if hasProtectedContent {
            return .unsupported(reason: "File is DRM-protected (e.g. an iTunes Store \"protected AAC\"/M4P purchase) and cannot be played back outside the app that licensed it.")
        }

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            return .unsupported(reason: "Could not read audio tracks: \(error.localizedDescription)")
        }
        guard let track = audioTracks.first else {
            return .unsupported(reason: "File contains no audio track.")
        }

        let formatDescriptions: [CMFormatDescription]
        do {
            formatDescriptions = try await track.load(.formatDescriptions)
        } catch {
            return .unsupported(reason: "Could not determine audio codec: \(error.localizedDescription)")
        }
        guard let formatDescription = formatDescriptions.first else {
            return .unsupported(reason: "Could not determine audio codec.")
        }

        let subType = CMFormatDescriptionGetMediaSubType(formatDescription)

        switch subType {
        case kAudioFormatMPEGLayer3:
            return .passThrough(SourceAudioFormat(kind: .mp3, filetypeMarker: fourCC("MP3 "), filetypeString: "MPEG audio file"))

        case kAudioFormatMPEG4AAC,
             kAudioFormatMPEG4AAC_HE,
             kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD,
             kAudioFormatMPEG4AAC_ELD_SBR,
             kAudioFormatMPEG4AAC_ELD_V2:
            return .passThrough(SourceAudioFormat(kind: .aac, filetypeMarker: fourCC("AAC "), filetypeString: "AAC audio file"))

        case kAudioFormatAppleLossless:
            return .passThrough(SourceAudioFormat(kind: .alac, filetypeMarker: fourCC("ALAC"), filetypeString: "Apple Lossless audio file"))

        case kAudioFormatLinearPCM:
            switch sniffPCMContainer(fileURL) {
            case .wav:
                return .passThrough(SourceAudioFormat(kind: .wav, filetypeMarker: fourCC("WAV "), filetypeString: "WAV audio file"))
            case .aiff:
                return .passThrough(SourceAudioFormat(kind: .aiff, filetypeMarker: fourCC("AIF "), filetypeString: "AIFF audio file"))
            case nil:
                return .unsupported(reason: "Unrecognized uncompressed-PCM container (neither RIFF/WAVE nor FORM/AIFF).")
            }

        default:
            let tag = fourCCString(subType)
            return .unsupported(reason: "Unsupported codec (\"\(tag)\") — classic players only play MP3, AAC, Apple Lossless, AIFF, and WAV.")
        }
    }

    // MARK: - Container sniffing

    private enum PCMContainer {
        case wav
        case aiff
    }

    /// Linear PCM is carried by both WAV and AIFF, which the codec alone
    /// can't distinguish — this reads the first 12 bytes of the actual file
    /// (RIFF/WAVE vs FORM/AIFF magic) rather than trusting the extension.
    private static func sniffPCMContainer(_ url: URL) -> PCMContainer? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12 else { return nil }

        let riff = header.subdata(in: 0..<4)
        let wave = header.subdata(in: 8..<12)
        if riff == Data("RIFF".utf8), wave == Data("WAVE".utf8) {
            return .wav
        }
        let form = header.subdata(in: 0..<4)
        let formType = header.subdata(in: 8..<12)
        if form == Data("FORM".utf8), formType == Data("AIFF".utf8) || formType == Data("AIFC".utf8) {
            return .aiff
        }
        return nil
    }

    // MARK: - FourCC helpers

    /// Packs a 4-character ASCII string into the little-endian `UInt32`
    /// layout `MHIT.Fields.filetypeMarker`/`ByteWriter.u32` expect (byte 0 in
    /// bits 0...7, byte 3 in bits 24...31), so the bytes as written to disk
    /// spell the string in order.
    private static func fourCC(_ s: String) -> UInt32 {
        let bytes = Array(s.utf8)
        precondition(bytes.count == 4, "fourCC requires exactly 4 ASCII bytes, got \(s)")
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[i]) << (8 * i) }
        return v
    }

    private static func fourCCString(_ v: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((v >> 24) & 0xff),
            UInt8((v >> 16) & 0xff),
            UInt8((v >> 8) & 0xff),
            UInt8(v & 0xff),
        ]
        if let s = String(bytes: bytes, encoding: .ascii), s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) {
            return s
        }
        return String(format: "0x%08x", v)
    }
}
