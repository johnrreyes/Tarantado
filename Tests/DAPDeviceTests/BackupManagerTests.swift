import Foundation
import Testing
@testable import DAPDevice

@Suite struct BackupManagerTests {
    private func makeVolumeWithDatabaseFiles(_ root: URL) throws -> DAPVolume {
        let volume = try DAPVolume.validate(at: root)
        try Data("fake iTunesDB".utf8).write(to: volume.iTunesDBURL)
        try Data("fake iTunesPrefs".utf8).write(to: volume.iTunesPrefsURL)
        try Data("fake Play Counts".utf8).write(to: volume.playCountsURL)
        // iTunesPrefs.plist deliberately omitted to exercise "skip missing".
        return volume
    }

    @Test func backsUpExistingFilesAndSkipsMissingOnes() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolumeWithDatabaseFiles(root)
        let manager = BackupManager(volume: volume)

        let backup = try manager.createBackup()
        #expect(Set(backup.files) == ["iTunesDB", "iTunesPrefs", "Play Counts"])
        #expect(!backup.files.contains("iTunesPrefs.plist"))

        let backedUpDB = try Data(contentsOf: backup.directoryURL.appendingPathComponent("iTunesDB"))
        #expect(String(decoding: backedUpDB, as: UTF8.self) == "fake iTunesDB")
    }

    @Test func createBackupThrowsWhenNothingExists() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)
        let manager = BackupManager(volume: volume)

        #expect(throws: BackupManager.BackupError.self) {
            try manager.createBackup()
        }
    }

    @Test func listBackupsReturnsNewestFirst() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolumeWithDatabaseFiles(root)
        let manager = BackupManager(volume: volume)

        let t1 = Date(timeIntervalSince1970: 1_000_000)
        let t2 = Date(timeIntervalSince1970: 2_000_000)
        let t3 = Date(timeIntervalSince1970: 3_000_000)
        _ = try manager.createBackup(timestamp: t1)
        _ = try manager.createBackup(timestamp: t2)
        _ = try manager.createBackup(timestamp: t3)

        let backups = try manager.listBackups()
        #expect(backups.count == 3)
        #expect(backups.map(\.timestamp) == [t3, t2, t1])
    }

    @Test func repeatedBackupsAtTheSameTimestampGetUniqueDirectories() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolumeWithDatabaseFiles(root)
        let manager = BackupManager(volume: volume)

        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let first = try manager.createBackup(timestamp: timestamp)
        let second = try manager.createBackup(timestamp: timestamp)
        #expect(first.directoryURL.path != second.directoryURL.path)

        let backups = try manager.listBackups()
        #expect(backups.count == 2)
    }

    @Test func restoreWritesBackupContentsBackToLiveLocations() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolumeWithDatabaseFiles(root)
        let manager = BackupManager(volume: volume)

        let backup = try manager.createBackup()

        // Simulate corruption/mutation of the live database after backup.
        try Data("corrupted!".utf8).write(to: volume.iTunesDBURL)

        try manager.restore(backup)

        let restored = try Data(contentsOf: volume.iTunesDBURL)
        #expect(String(decoding: restored, as: UTF8.self) == "fake iTunesDB")
    }

    @Test func pruneKeepsOnlyTheNMostRecentBackups() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try makeVolumeWithDatabaseFiles(root)
        let manager = BackupManager(volume: volume)

        for i in 0..<5 {
            _ = try manager.createBackup(timestamp: Date(timeIntervalSince1970: Double(1_000_000 + i)))
        }
        #expect(try manager.listBackups().count == 5)

        let removed = try manager.prune(keeping: 2)
        #expect(removed.count == 3)

        let remaining = try manager.listBackups()
        #expect(remaining.count == 2)
        // The two newest should have survived.
        #expect(remaining[0].timestamp == Date(timeIntervalSince1970: 1_000_004))
        #expect(remaining[1].timestamp == Date(timeIntervalSince1970: 1_000_003))
    }

    // MARK: atomicWrite

    @Test func atomicWriteCreatesNewFileWithCorrectContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("file.bin")
        try BackupManager.atomicWrite(Data("hello".utf8), to: target)

        #expect(try Data(contentsOf: target) == Data("hello".utf8))
        // No leftover temp files.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["file.bin"])
    }

    @Test func atomicWriteOverwritesExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("file.bin")
        try Data("old".utf8).write(to: target)

        try BackupManager.atomicWrite(Data("new".utf8), to: target)

        #expect(try Data(contentsOf: target) == Data("new".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["file.bin"])
    }

    @Test func atomicWriteForcedFallbackPathWorksAndLeavesNoTempFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("file.bin")
        try Data("old".utf8).write(to: target)

        // Exercise the remove-then-move fallback directly (this is the
        // path used on filesystems, like FAT32, where replaceItemAt can't
        // be relied on).
        try BackupManager.atomicWrite(Data("new-via-fallback".utf8), to: target, forceFallback: true)

        #expect(try Data(contentsOf: target) == Data("new-via-fallback".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["file.bin"])
    }

    @Test func atomicWriteForcedFallbackCreatesNewFileWhenNoneExists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("file.bin")
        try BackupManager.atomicWrite(Data("brand-new".utf8), to: target, forceFallback: true)

        #expect(try Data(contentsOf: target) == Data("brand-new".utf8))
    }
}
