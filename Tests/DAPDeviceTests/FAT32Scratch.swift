import Foundation

/// Creates a genuine FAT32 volume via `hdiutil`.
///
/// Some iPod behaviour cannot be reproduced on APFS at all — most notably
/// AppleDouble `._` sidecars, which macOS folds into extended attributes on a
/// native filesystem but writes as real files on FAT32. Tests that care about
/// what actually happens on a classic iPod need the real thing.
///
/// Returns `nil` (rather than failing) when `hdiutil` is unavailable, so the
/// suite still passes on machines and CI images that cannot mount disk images.
enum FAT32Scratch {
    static func mount() throws -> URL? {
        let name = "IOPTEST\(Int.random(in: 1000...9999))"
        let image = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name).dmg")

        guard run("/usr/bin/hdiutil", [
            "create", "-fs", "MS-DOS", "-size", "10m", "-volname", name,
            "-quiet", image.deletingPathExtension().path,
        ]) else { return nil }

        guard run("/usr/bin/hdiutil", ["attach", image.path, "-quiet"]) else {
            try? FileManager.default.removeItem(at: image)
            return nil
        }

        let mounted = URL(fileURLWithPath: "/Volumes/\(name)")
        guard FileManager.default.fileExists(atPath: mounted.path) else { return nil }
        return mounted
    }

    static func unmount(_ volume: URL) {
        _ = run("/usr/bin/hdiutil", ["detach", volume.path, "-quiet", "-force"])
        let image = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(volume.lastPathComponent).dmg")
        try? FileManager.default.removeItem(at: image)
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
