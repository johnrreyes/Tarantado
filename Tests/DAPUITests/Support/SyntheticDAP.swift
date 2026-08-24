import Foundation
import Testing
import DAPDevice

/// Builds a synthetic iPod volume in a temp directory, so the model's edit
/// operations can be exercised against a real `DAPVolume` and a real
/// database with no device attached.
///
/// A third copy of this helper (DAPDeviceTests and DAPSyncTests have their
/// own): SwiftPM test targets can't share support code, and the alternative —
/// a library target existing only for tests — would ship in the package's
/// products.
enum SyntheticDAP {
    static let mini2gSysInfoText = """
    BoardHwName: iPod Q22B
    pszSerialNumber: EXAMPLE0001
    ModelNumStr: M9800
    FirewireGuid: 0x000A270000000001
    HddFirmwareRev: Rev 3.72
    RegionCode: LL(0x0001)
    visibleBuildID: 0x01418000 (1.4.1)
    iPodFamily: 0x00000003
    """

    static func goldenDatabaseURL() throws -> URL {
        for candidate in ["Resources/golden-mini2g", "golden-mini2g"] {
            if let url = Bundle.module.url(forResource: candidate, withExtension: "itunesdb") {
                return url
            }
        }
        if let url = Bundle.module.url(forResource: "golden-mini2g", withExtension: "itunesdb", subdirectory: "Resources") {
            return url
        }
        Issue.record("Could not locate golden-mini2g.itunesdb in Bundle.module")
        throw CocoaError(.fileNoSuchFile)
    }

    @discardableResult
    static func make(musicFolderCount: Int = 50) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("DAPUITests-\(UUID().uuidString)", isDirectory: true)

        let control = root.appendingPathComponent("iPod_Control", isDirectory: true)
        let device = control.appendingPathComponent("Device", isDirectory: true)
        let iTunes = control.appendingPathComponent("iTunes", isDirectory: true)
        let music = control.appendingPathComponent("Music", isDirectory: true)
        try fileManager.createDirectory(at: device, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: iTunes, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: music, withIntermediateDirectories: true)
        for index in 0..<musicFolderCount {
            try fileManager.createDirectory(
                at: music.appendingPathComponent(String(format: "F%02d", index), isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        try mini2gSysInfoText.write(to: device.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)
        try fileManager.copyItem(at: try goldenDatabaseURL(), to: iTunes.appendingPathComponent("iTunesDB"))
        return root
    }

    static func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }
}
