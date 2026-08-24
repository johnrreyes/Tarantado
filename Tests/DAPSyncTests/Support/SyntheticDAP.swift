import Foundation
import DAPDevice

/// Materializes a synthetic iPod volume layout in a fresh temp directory,
/// mirroring `Tests/DAPDeviceTests/SyntheticDAP.swift`'s approach (that
/// helper is `@testable import DAPDevice`-internal to its own test target
/// and can't be shared across targets, so this is a small independent copy
/// built entirely on DAPDevice's public API).
///
/// Tests must never write to a real mounted iPod — everything here writes
/// only under `FileManager.default.temporaryDirectory`.
enum SyntheticDAP {
    /// Verbatim copy of `Tests/DAPDeviceTests/SysInfo-mini2g.txt` (a real
    /// mini 2nd-gen SysInfo, ModelNumStr M9800 — no database-signature
    /// requirement, 50 music folders), inlined so this target doesn't need
    /// its own declared test resource.
    static let mini2gSysInfoText = """
    BoardHwName: iPod Q22B
    pszSerialNumber: EXAMPLE0001
    ModelNumStr: M9800
    FirewireGuid: 0x000A270000000001
    HddFirmwareRev: Rev 3.72
    RegionCode: LL(0x0001)
    PolicyFlags: 0x00000000
    buildID: 0x02618000 (2.6.1)
    visibleBuildID: 0x01418000 (1.4.1)
    boardHwRev: 0x00000000 (0.0 0)
    boardHwSwInterfaceRev: 0x00070002 (0.0.7 2)
    bootLoaderImageRev: 0x00000000 (0.0 0)
    diskModeImageRev: 0x00000000 (0.0 0)
    diagImageRev: 0x00000000 (0.0 0)
    osImageRev: 0x00000000 (0.0 0)
    iPodFamily: 0x00000003
    updaterFamily: 0x00000006
    """

    /// Creates a new synthetic iPod under a unique temp directory and
    /// returns its root URL. When `withGoldenDatabase` is true (the
    /// default), the real 0-track golden fixture is copied in as the live
    /// `iTunesDB` so tests exercise the actual on-disk format rather than a
    /// hand-built stand-in. Callers are responsible for removing the
    /// returned directory (typically via `defer`).
    @discardableResult
    static func make(musicFolderCount: Int = 50, withGoldenDatabase: Bool = true) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("DAPSyncTests-\(UUID().uuidString)", isDirectory: true)

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

        try mini2gSysInfoText.write(
            to: deviceDirectory.appendingPathComponent("SysInfo", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        if withGoldenDatabase {
            let goldenURL = try GoldenDatabase.url()
            try fileManager.copyItem(
                at: goldenURL,
                to: iTunesDirectory.appendingPathComponent("iTunesDB", isDirectory: false)
            )
        }

        return root
    }

    /// Removes a synthetic iPod created by `make(...)`. Safe to call even
    /// if the directory was already removed.
    static func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Recursively lists every regular file under a synthetic iPod's music
    /// directory, relative to the volume root — used to assert "no orphaned
    /// files were left behind" by comparing a before/after snapshot.
    static func musicFileListing(_ volume: DAPVolume) -> Set<String> {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: volume.musicDirectory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var result = Set<String>()
        let rootPath = volume.rootURL.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath) {
                result.insert(String(path.dropFirst(rootPath.count)))
            }
        }
        return result
    }
}
