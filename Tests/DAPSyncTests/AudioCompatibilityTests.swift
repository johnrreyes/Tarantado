import Foundation
import Testing
import DAPDevice
@testable import DAPSync

@Suite struct AudioCompatibilityTests {
    private static let mini2gModel = DeviceModel(
        displayName: "iPod mini (2nd generation)",
        generation: "mini 2G",
        family: .mini,
        requiresDatabaseSignature: .none,
        supportsArtwork: false,
        musicFolderCount: 50
    )

    @Test func wavFileClassifiesAsPassThrough() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("silence.wav")
        try SyntheticAudio.makeWAV(at: url)
        let size = try Int64((FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)

        let result = await AudioCompatibilityChecker.classify(fileURL: url, fileSize: size, model: Self.mini2gModel)
        guard case .passThrough(let format) = result else {
            Issue.record("expected passThrough, got \(result)")
            return
        }
        #expect(format.kind == .wav)
    }

    @Test func aacFileClassifiesAsPassThrough() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("silence.m4a")
        try await SyntheticAudio.makeAAC(at: url, tags: SyntheticAudio.Tags(title: "T"))
        let size = try Int64((FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)

        let result = await AudioCompatibilityChecker.classify(fileURL: url, fileSize: size, model: Self.mini2gModel)
        guard case .passThrough(let format) = result else {
            Issue.record("expected passThrough, got \(result)")
            return
        }
        #expect(format.kind == .aac)
    }

    @Test func oversizedFileIsRejected() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("huge.wav")
        try SyntheticAudio.makeWAV(at: url)

        let result = await AudioCompatibilityChecker.classify(
            fileURL: url,
            fileSize: AudioCompatibilityChecker.fat32MaxFileSize,
            model: Self.mini2gModel
        )
        guard case .unsupported(let reason) = result else {
            Issue.record("expected unsupported, got \(result)")
            return
        }
        #expect(reason.contains("FAT32"))
    }

    @Test func emptyFileIsRejected() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("empty.mp3")
        try Data().write(to: url)

        let result = await AudioCompatibilityChecker.classify(fileURL: url, fileSize: 0, model: Self.mini2gModel)
        guard case .unsupported = result else {
            Issue.record("expected unsupported, got \(result)")
            return
        }
    }

    /// `AVAudioFile` (the *writer*) infers its container from the
    /// extension it's given, but `AVURLAsset` (the *reader*, which is what
    /// `classify` uses) sniffs the actual bytes and ignores a misleading
    /// extension — confirming classification is genuinely content-based,
    /// not extension-based, exactly as required.
    @Test func mislabeledExtensionIsClassifiedByActualContentNotExtension() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a real WAV file with a `.wav` extension (required for
        // AVAudioFile's writer to produce the right container), then rename
        // it as if it were something else entirely — only `classify` ever
        // sees the mismatched extension.
        let wavURL = dir.appendingPathComponent("real.wav")
        try SyntheticAudio.makeWAV(at: wavURL)
        let url = dir.appendingPathComponent("not-actually-flac.flac")
        try FileManager.default.moveItem(at: wavURL, to: url)
        let size = try Int64((FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)

        let result = await AudioCompatibilityChecker.classify(fileURL: url, fileSize: size, model: Self.mini2gModel)
        guard case .passThrough(let format) = result else {
            Issue.record("expected content-based classification to see through the misleading extension, got \(result)")
            return
        }
        #expect(format.kind == .wav)
    }

    @Test func wavContainerIsRecognizedByContent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("plain.wav")
        try SyntheticAudio.makeWAV(at: url)
        let size = try Int64((FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)

        let result = await AudioCompatibilityChecker.classify(fileURL: url, fileSize: size, model: Self.mini2gModel)
        guard case .passThrough(let format) = result else {
            Issue.record("expected passThrough, got \(result)")
            return
        }
        #expect(format.kind == .wav)
        #expect(format.filetypeString == "WAV audio file")
    }

    // MARK: - Real hardware smoke tests (skipped if the iPod isn't mounted)

    private static let realMusicDirectory = "/Volumes/JOHNREYES'S/Music"

    @Test func realMP3FromDeviceClassifiesAsPassThroughMP3() async throws {
        guard let mp3URL = Self.firstRealFile(extension: "mp3") else { return }
        let size = try Int64((FileManager.default.attributesOfItem(atPath: mp3URL.path)[.size] as? Int) ?? 0)
        let result = await AudioCompatibilityChecker.classify(fileURL: mp3URL, fileSize: size, model: Self.mini2gModel)
        guard case .passThrough(let format) = result else {
            Issue.record("expected passThrough for a real MP3 from the device, got \(result)")
            return
        }
        #expect(format.kind == .mp3)
    }

    @Test func realM4AFromDeviceClassifiesAsPassThroughAACOrALAC() async throws {
        guard let m4aURL = Self.firstRealFile(extension: "m4a") else { return }
        let size = try Int64((FileManager.default.attributesOfItem(atPath: m4aURL.path)[.size] as? Int) ?? 0)
        let result = await AudioCompatibilityChecker.classify(fileURL: m4aURL, fileSize: size, model: Self.mini2gModel)
        guard case .passThrough(let format) = result else {
            Issue.record("expected passThrough for a real M4A from the device, got \(result)")
            return
        }
        #expect(format.kind == .aac || format.kind == .alac)
    }

    private static func firstRealFile(extension ext: String) -> URL? {
        let root = URL(fileURLWithPath: realMusicDirectory, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == ext {
            return url
        }
        return nil
    }
}
