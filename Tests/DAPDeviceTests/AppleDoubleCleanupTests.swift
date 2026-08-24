import Foundation
import Testing
@testable import DAPDevice

/// Classic iPods are FAT32, where macOS stores any extended attribute in a
/// companion `._NAME` file. macOS stamps `com.apple.provenance` onto written
/// files by itself, so every write to the device leaves litter unless it is
/// cleaned up. Observed on a physical iPod mini 2G: 10 sidecars from a single
/// sync — beside the database, the backup directory, and every backed-up file.
struct AppleDoubleCleanupTests {
    private func makeScratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func stripRemovesSidecarButKeepsTheRealFile() throws {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("iTunesDB")
        try Data("db".utf8).write(to: file)
        try Data(repeating: 0, count: 4096).write(to: dir.appendingPathComponent("._iTunesDB"))

        AppleDoubleCleanup.strip(at: file)

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("._iTunesDB").path))
        #expect(try Data(contentsOf: file) == Data("db".utf8))
    }

    @Test func stripWorksOnDirectoriesToo() throws {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let backups = dir.appendingPathComponent(".iopenpod-backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096)
            .write(to: dir.appendingPathComponent("._.iopenpod-backups"))

        AppleDoubleCleanup.strip(at: backups)

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("._.iopenpod-backups").path))
        #expect(FileManager.default.fileExists(atPath: backups.path))
    }

    /// `._` files cannot be created on APFS — macOS intercepts them and folds
    /// them into the real file's extended attributes, so they are invisible even
    /// to `contentsOfDirectory`. They only exist as genuine files on FAT32,
    /// which is precisely why this bug only ever appeared on the iPod. So this
    /// test builds a real FAT32 volume rather than pretending on the host disk.
    @Test func stripRecursivelySweepsSidecarsOnARealFAT32Volume() throws {
        guard let volume = try FAT32Scratch.mount() else { return } // hdiutil unavailable
        defer { FAT32Scratch.unmount(volume) }

        let nested = volume.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        // Writing an xattr on FAT32 is what materializes the sidecar.
        for path in ["one.mp3", "a/two.mp3", "a/b/three.mp3"] {
            let file = volume.appendingPathComponent(path)
            try Data("audio".utf8).write(to: file)
            file.withUnsafeFileSystemRepresentation { p in
                let value = Array("x".utf8)
                _ = setxattr(p, "com.example.test", value, value.count, 0, 0)
            }
        }

        let removed = AppleDoubleCleanup.stripRecursively(in: volume)
        #expect(removed > 0, "FAT32 materialized no sidecars; the test proved nothing")

        // A second sweep must find nothing — proving the first one was complete,
        // not merely that it deleted something.
        #expect(AppleDoubleCleanup.stripRecursively(in: volume) == 0)

        // And the real files must survive untouched.
        #expect(try Data(contentsOf: volume.appendingPathComponent("a/b/three.mp3")) == Data("audio".utf8))
        #expect(try Data(contentsOf: volume.appendingPathComponent("one.mp3")) == Data("audio".utf8))
    }

    @Test func backupsLeaveNoSidecarsBehind() throws {
        let pod = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(pod) }

        let volume = try DAPVolume.validate(at: pod)
        try Data("database".utf8).write(to: volume.iTunesDBURL)

        _ = try BackupManager(volume: volume).createBackup(timestamp: Date())
        try BackupManager.atomicWrite(Data("updated".utf8), to: volume.iTunesDBURL)

        var found: [String] = []
        if let walker = FileManager.default.enumerator(at: volume.controlDirectory, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.lastPathComponent.hasPrefix("._") {
                found.append(url.lastPathComponent)
            }
        }
        #expect(found.isEmpty, "AppleDouble sidecars left behind: \(found)")
    }
}
