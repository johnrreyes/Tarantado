import Foundation

/// Removes the AppleDouble artifacts macOS leaves on FAT32 volumes.
///
/// Every player Tarantado supports is FAT32, which has no native support for
/// extended attributes. When macOS needs to store one it writes a companion
/// `._NAME`
/// file — 4 KB apiece — beside the real file. This is not something we ask
/// for: recent macOS releases stamp `com.apple.provenance` onto written files
/// automatically, which alone is enough to litter the device.
///
/// Observed on a physical iPod mini 2G: a `._FUOR.mp3` beside every copied
/// track, plus `._iTunesDB` and `._.iopenpod-backups` beside the database and
/// backup directory. Across a full library that is roughly 900 junk files.
/// iTunes leaves none of them.
///
/// `com.apple.provenance` itself is system-protected and cannot be removed —
/// even `xattr -c` leaves it in place — so removing the sidecar afterwards is
/// the only reliable fix. Call this after *any* write to a DAP volume,
/// including directory creation.
public enum AppleDoubleCleanup {
    /// Strips removable extended attributes from `url` and deletes the
    /// AppleDouble sidecar the filesystem may have materialized for it.
    /// Safe to call on files and directories, and on volumes that need none
    /// of this (where it is a no-op).
    public static func strip(at url: URL) {
        removeExtendedAttributes(at: url)

        let sidecar = url
            .deletingLastPathComponent()
            .appendingPathComponent("._" + url.lastPathComponent)
        try? FileManager.default.removeItem(at: sidecar)
    }

    /// Removes every AppleDouble sidecar found anywhere beneath `directory`,
    /// returning how many were deleted.
    ///
    /// This deliberately uses `readdir` rather than `FileManager`. On FAT32
    /// macOS **hides AppleDouble entries from `contentsOfDirectory` and
    /// `enumerator`** — they are filtered out of directory listings even though
    /// `fileExists(atPath:)` reports them present and `removeItem` deletes them
    /// happily. A FileManager-based sweep therefore always finds zero files and
    /// silently does nothing, which is exactly the trap this implementation
    /// exists to avoid. `readdir` sees the real directory contents.
    @discardableResult
    public static func stripRecursively(in directory: URL) -> Int {
        var removed = 0
        var pending = [directory]

        while let current = pending.popLast() {
            for entry in rawDirectoryEntries(at: current) {
                let url = current.appendingPathComponent(entry)

                if entry.hasPrefix("._") {
                    if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
                    continue
                }
                if entry == "." || entry == ".." { continue }

                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    pending.append(url)
                }
            }
        }
        return removed
    }

    /// The true contents of a directory, including entries `FileManager` hides.
    private static func rawDirectoryEntries(at url: URL) -> [String] {
        guard let handle = opendir(url.path) else { return [] }
        defer { closedir(handle) }

        var entries: [String] = []
        while let pointer = readdir(handle) {
            var nameBuffer = pointer.pointee.d_name
            let name = withUnsafePointer(to: &nameBuffer) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(pointer.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { entries.append(name) }
        }
        return entries
    }

    private static func removeExtendedAttributes(at url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }

            let size = listxattr(path, nil, 0, 0)
            guard size > 0 else { return }

            var names = [CChar](repeating: 0, count: size)
            guard listxattr(path, &names, size, 0) == size else { return }

            // The buffer is a run of NUL-terminated attribute names.
            var start = 0
            for index in 0..<size where names[index] == 0 {
                if index > start {
                    let name = String(cString: Array(names[start..<index]) + [0])
                    _ = removexattr(path, name, 0)
                }
                start = index + 1
            }
        }
    }
}
