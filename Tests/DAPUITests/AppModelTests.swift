import Foundation
import Testing
import DAPDB
import DAPDevice
import DAPSync
@testable import DAPUI

@Suite struct AppModelTests {
    // MARK: - Sync-support rule

    @Test func refusesUnidentifiedDevices() {
        let support = AppModel.evaluateSyncSupport(for: .unknown)
        #expect(support.isSupported == false)
        #expect(support.reason?.isEmpty == false)
    }

    @Test func refusesDevicesRequiringADatabaseSignature() {
        let classic = DeviceModel(
            displayName: "iPod classic (6th generation)",
            generation: "classic 6G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .hash58,
            supportsArtwork: true,
            musicFolderCount: 50
        )
        let support = AppModel.evaluateSyncSupport(for: classic)
        #expect(support.isSupported == false)
    }

    @Test func allowsTheVerifiedMini2G() throws {
        let mini = try #require(DeviceModel.resolve(from: SysInfo(parsing: Self.mini2gSysInfo)))
        let support = AppModel.evaluateSyncSupport(for: mini)
        #expect(support.isSupported)
        #expect(support.reason == nil)
    }

    // MARK: - Selection

    @MainActor
    @Test func selectionIgnoresIncompatibleTracks() {
        let model = AppModel(localLibrary: nil)
        let playable = Self.sourceTrack(name: "ok.mp3", compatible: true)
        let unplayable = Self.sourceTrack(name: "bad.flac", compatible: false)

        model.toggleSelection(for: playable)
        #expect(model.selectedFileURLs.contains(playable.fileURL))

        // An unsupported file can never be selected, so the Review screen
        // can't be handed something the engine would only skip anyway.
        model.toggleSelection(for: unplayable)
        #expect(model.selectedFileURLs.contains(unplayable.fileURL) == false)
    }

    @MainActor
    @Test func togglingTwiceDeselects() {
        let model = AppModel(localLibrary: nil)
        let track = Self.sourceTrack(name: "ok.mp3", compatible: true)

        model.toggleSelection(for: track)
        model.toggleSelection(for: track)
        #expect(model.selectedFileURLs.isEmpty)
    }

    // MARK: - Plan

    @MainActor
    @Test func computingAPlanWithNoDeviceConnectedYieldsNoPlan() {
        let model = AppModel(localLibrary: nil)
        model.computePlan()
        #expect(model.plan == nil)
    }

    // MARK: - Error formatting

    @Test func surfacesAnEngineErrorsOwnDescriptionVerbatim() {
        // The engine's errors are already written to be read by a user, so
        // the UI must not replace them with a generic message.
        let error = SyncEngineError.insufficientSpace(required: 100, available: 10)
        let message = AppModel.friendlyMessage(for: error)
        #expect(message == error.errorDescription)
        #expect(message.contains("100"))
    }

    @Test func fallsBackToLocalizedDescriptionForPlainErrors() {
        struct Plain: Error {}
        let message = AppModel.friendlyMessage(for: Plain())
        #expect(message.isEmpty == false)
    }

    // MARK: - Fixtures

    private static func sourceTrack(name: String, compatible: Bool) -> SourceTrack {
        SourceTrack(
            fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
            fileSize: 1000,
            title: name,
            artist: "Artist",
            durationMS: 1000,
            compatibility: compatible
                ? .passThrough(SourceAudioFormat(kind: .mp3, filetypeMarker: 0, filetypeString: "MPEG audio file"))
                : .unsupported(reason: "Not playable by this iPod")
        )
    }

    private static let mini2gSysInfo = """
    BoardHwName: iPod Q22B
    pszSerialNumber: EXAMPLE0001
    ModelNumStr: M9800
    visibleBuildID: 0x01418000 (1.4.1)
    """

    // MARK: - Scanning

    @MainActor
    @Test func scanningAFolderWithNoAudioEndsScannedAndEmptyRatherThanIdle() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "not audio".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let model = AppModel(localLibrary: nil)
        model.sourceFolderURL = folder
        model.startScan()

        try await Self.waitForScanToFinish(model)

        // The distinction matters to the view: `.idle` means "no folder
        // chosen yet", `.scanned` with no tracks means "we looked and found
        // nothing". Collapsing them renders a blank pane that reads as the
        // folder picker having done nothing at all.
        #expect(model.scanState == .scanned)
        #expect(model.sourceTracks.isEmpty)
    }

    @MainActor
    @Test func scanningFindsAudioFilesButSelectsNothingByItself() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = folder.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.writeWAV(to: nested.appendingPathComponent("song.wav"))

        let model = AppModel(localLibrary: nil)
        model.sourceFolderURL = folder
        model.startScan()

        try await Self.waitForScanToFinish(model)

        #expect(model.scanState == .scanned)
        // Found inside a subfolder — the scan is recursive.
        #expect(model.sourceTracks.count == 1)
        // A scan proposes nothing. The library is rescanned on launch and
        // after every import, so selecting its contents would repeatedly
        // propose resyncing everything and arm the destructive
        // "Remove from Library" button unasked.
        #expect(model.selectedFileURLs.isEmpty)
    }

    /// A rescan must not silently drop what the user had ticked — but a
    /// track deleted from the library since the last scan has to go.
    @MainActor
    @Test func rescanningKeepsSelectionsThatAreStillValid() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = folder.appendingPathComponent("kept.wav")
        let removed = folder.appendingPathComponent("removed.wav")
        try Self.writeWAV(to: kept)
        try Self.writeWAV(to: removed)

        let model = AppModel(localLibrary: nil)
        model.sourceFolderURL = folder
        model.startScan()
        try await Self.waitForScanToFinish(model)

        // Select through the model's own tracks, the way the UI does — the
        // scanner reports resolved paths (/private/var), so hand-built URLs
        // would not compare equal to them.
        #expect(model.sourceTracks.count == 2)
        for track in model.sourceTracks { model.toggleSelection(for: track) }
        #expect(model.selectedFileURLs.count == 2)

        let keptURL = try #require(model.sourceTracks.first { $0.fileURL.lastPathComponent == "kept.wav" }).fileURL
        try FileManager.default.removeItem(at: removed)

        model.startScan()
        try await Self.waitForScanToFinish(model)

        let selected = model.selectedFileURLs
        #expect(selected == [keptURL])
    }

    @MainActor
    private static func waitForScanToFinish(_ model: AppModel) async throws {
        for _ in 0..<200 {
            switch model.scanState {
            case .scanned, .failed, .cancelled: return
            default: try await Task.sleep(for: .milliseconds(25))
            }
        }
        Issue.record("scan did not finish in time (state: \(model.scanState))")
    }

    /// Minimal 16-bit stereo PCM WAV — enough for AVAsset to open and for
    /// the scanner to classify.
    private static func writeWAV(to url: URL, seconds: Double = 0.2, sampleRate: Int = 44_100) throws {
        let frames = Int(Double(sampleRate) * seconds)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        let dataBytes = frames * 4
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(2)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 4)); append(UInt16(4)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
        for n in 0..<frames {
            let v = Int16(truncatingIfNeeded: Int(12000 * sin(2 * Double.pi * 440 * Double(n) / Double(sampleRate))))
            append(v); append(v)
        }
        try data.write(to: url)
    }
}
