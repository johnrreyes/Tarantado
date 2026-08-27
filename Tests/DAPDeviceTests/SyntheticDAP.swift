import Foundation
@testable import DAPDevice

/// Materializes a synthetic iPod volume layout in a fresh temporary
/// directory: `iPod_Control/{Device,iTunes,Music/F00...F<N-1>}`, with the
/// real sample `SysInfo` written into place.
///
/// Tests must never write to a real mounted iPod — everything that needs a
/// writable volume should be built with this instead.
enum SyntheticDAP {
    /// Creates a new synthetic iPod under a unique temp directory and
    /// returns its root URL. Callers are responsible for removing it (see
    /// `remove(_:)`) — typically via `defer`.
    @discardableResult
    static func make(
        musicFolderCount: Int = 50,
        sysInfoText: String? = nil,
        writeSysInfo: Bool = true,
        sysInfoExtendedXML: String? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("DAPDeviceTests-\(UUID().uuidString)", isDirectory: true)

        let controlDirectory = root.appendingPathComponent("iPod_Control", isDirectory: true)
        let deviceDirectory = controlDirectory.appendingPathComponent("Device", isDirectory: true)
        let iTunesDirectory = controlDirectory.appendingPathComponent("iTunes", isDirectory: true)
        let musicDirectory = controlDirectory.appendingPathComponent("Music", isDirectory: true)

        try fileManager.createDirectory(at: deviceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: iTunesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)

        for index in 0..<musicFolderCount {
            let folderName = String(format: "F%02d", index)
            try fileManager.createDirectory(
                at: musicDirectory.appendingPathComponent(folderName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        if writeSysInfo {
            let text = try sysInfoText ?? String(contentsOf: sampleSysInfoURL, encoding: .utf8)
            try text.write(
                to: deviceDirectory.appendingPathComponent("SysInfo", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }

        if let sysInfoExtendedXML {
            try sysInfoExtendedXML.write(
                to: deviceDirectory.appendingPathComponent("SysInfoExtended", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }

        return root
    }

    /// Removes a synthetic iPod created by `make(...)`. Safe to call even
    /// if the directory was already removed.
    static func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    /// URL of the bundled copy of the real mini 2G SysInfo. Verbatim except
    /// for the serial number and FireWire GUID, which are anonymized — no
    /// code reads either one to identify a model.
    static var sampleSysInfoURL: URL {
        fixtureURL("SysInfo-mini2g.txt")
    }

    /// URL of the bundled copy of the real iPod 4G (M9282) SysInfo. Same
    /// anonymization as the mini 2G fixture above.
    static var sampleSysInfo4GURL: URL {
        fixtureURL("SysInfo-ipod4g.txt")
    }

    /// URL of the bundled copy of the real iPod 5G ("video")
    /// `SysInfoExtended`. Verbatim except for the serial number and
    /// FireWire GUID, which are anonymized the same way the two SysInfo
    /// fixtures above are.
    ///
    /// Note what this file does *not* contain: `ModelNumStr` or
    /// `BoardHwName`. That absence is the point of keeping it — it is why
    /// a real 5G resolves through the `iPodFamily` fallback rather than the
    /// SKU table, and it is exactly what a doctored fixture would paper over.
    static var sampleSysInfoExtended5GURL: URL {
        fixtureURL("SysInfoExtended-ipod5g.xml")
    }

    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(name)
    }
}
