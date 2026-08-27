import Foundation

/// Snapshots and restores a DAP's database files
/// (`iTunesDB`, `iTunesPrefs`, `iTunesPrefs.plist`, `Play Counts`) so a
/// failed or interrupted write never leaves the device with no usable
/// database.
///
/// Backups live under `iPod_Control/iTunes/.iopenpod-backups/<timestamp>/`
/// on the device itself (not on the host), so they travel with it
/// and survive an app reinstall.
public struct BackupManager: Sendable {
    public let volume: DAPVolume

    public init(volume: DAPVolume) {
        self.volume = volume
    }

    /// A single point-in-time snapshot.
    public struct Backup: Sendable, Equatable {
        public let timestamp: Date
        public let directoryURL: URL
        /// Filenames actually captured in this backup (files that didn't
        /// exist on the device at backup time are simply absent here).
        public let files: [String]
    }

    public enum BackupError: Error, LocalizedError, Equatable {
        case nothingToBackUp
        case unrecognizedFile(String)

        public var errorDescription: String? {
            switch self {
            case .nothingToBackUp:
                return "None of the database files exist on this device yet; nothing to back up."
            case .unrecognizedFile(let name):
                return "\"\(name)\" isn't one of the files BackupManager knows how to restore."
            }
        }
    }

    /// Fixed backup order: the set of files a backup captures.
    ///
    /// `ArtworkDB` is included, but the `.ithmb` pixel files it references
    /// are not — those are large, regenerable from `ArtworkDB` + the source
    /// library, and backing up every thumbnail on every sync would make
    /// backups far more expensive for comparatively little safety: an
    /// `ArtworkDB` restored without its `.ithmb` files just shows blank/stale
    /// art for whatever changed, not a corrupt database.
    private static let managedFileOrder = ["iTunesDB", "iTunesPrefs", "iTunesPrefs.plist", "Play Counts", "ArtworkDB"]

    /// Maps a managed filename to its live destination URL on `volume`.
    private static func destination(forFileNamed fileName: String, on volume: DAPVolume) -> URL? {
        switch fileName {
        case "iTunesDB": return volume.iTunesDBURL
        case "iTunesPrefs": return volume.iTunesPrefsURL
        case "iTunesPrefs.plist": return volume.iTunesPrefsPlistURL
        case "Play Counts": return volume.playCountsURL
        case "ArtworkDB": return volume.artworkDBURL
        default: return nil
        }
    }

    public var backupsDirectory: URL {
        volume.iTunesDirectory.appendingPathComponent(".iopenpod-backups", isDirectory: true)
    }

    /// ISO 8601 "basic" format (no `:` or `-` separators), e.g.
    /// `20260817T143012Z`. This is deliberately not the "extended" format
    /// (`2026-08-17T14:30:12Z`) because `:` is not a legal character in a
    /// FAT32 short or long filename — using it would make the backup
    /// directory itself unwritable on the device's actual filesystem.
    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    // MARK: Creating backups

    /// Copies every existing managed database file into a new timestamped
    /// directory under `backupsDirectory`. Files that don't currently
    /// exist on the device are silently skipped. Throws
    /// `BackupError.nothingToBackUp` if none of the files exist.
    @discardableResult
    public func createBackup(timestamp: Date = Date()) throws -> Backup {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        AppleDoubleCleanup.strip(at: backupsDirectory)

        let targetDirectory = try makeUniqueBackupDirectory(for: timestamp, fileManager: fileManager)

        var capturedFiles: [String] = []
        for fileName in Self.managedFileOrder {
            guard let source = Self.destination(forFileNamed: fileName, on: volume) else { continue }
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = targetDirectory.appendingPathComponent(fileName, isDirectory: false)
            try fileManager.copyItem(at: source, to: destination)
            // copyItem preserves extended attributes, which on FAT32 means a
            // 4 KB `._NAME` sidecar per backed-up file.
            AppleDoubleCleanup.strip(at: destination)
            capturedFiles.append(fileName)
        }

        guard !capturedFiles.isEmpty else {
            try? fileManager.removeItem(at: targetDirectory)
            throw BackupError.nothingToBackUp
        }

        return Backup(timestamp: timestamp, directoryURL: targetDirectory, files: capturedFiles)
    }

    private func makeUniqueBackupDirectory(for timestamp: Date, fileManager: FileManager) throws -> URL {
        let baseName = Self.timestampFormatter.string(from: timestamp)
        var candidateName = baseName
        var suffix = 1
        while fileManager.fileExists(atPath: backupsDirectory.appendingPathComponent(candidateName).path) {
            candidateName = "\(baseName)-\(suffix)"
            suffix += 1
        }
        let targetDirectory = backupsDirectory.appendingPathComponent(candidateName, isDirectory: true)
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        AppleDoubleCleanup.strip(at: targetDirectory)
        return targetDirectory
    }

    // MARK: Listing

    /// All backups currently on the device, newest first.
    public func listBackups() throws -> [Backup] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupsDirectory.path) else { return [] }

        let entries = try fileManager.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        var backups: [Backup] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            let name = entry.lastPathComponent
            let baseName = String(name.split(separator: "-", maxSplits: 1).first ?? Substring(name))
            guard let timestamp = Self.timestampFormatter.date(from: baseName) else { continue }

            let files = ((try? fileManager.contentsOfDirectory(atPath: entry.path)) ?? [])
                .filter { Self.managedFileOrder.contains($0) }
                .sorted()
            backups.append(Backup(timestamp: timestamp, directoryURL: entry, files: files))
        }
        return backups.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: Restoring

    /// Restores every file captured in `backup` back to its live location,
    /// using `atomicWrite` so a failure partway through never leaves a
    /// live file half-written.
    public func restore(_ backup: Backup) throws {
        let fileManager = FileManager.default
        for fileName in backup.files {
            guard let destination = Self.destination(forFileNamed: fileName, on: volume) else {
                throw BackupError.unrecognizedFile(fileName)
            }
            let source = backup.directoryURL.appendingPathComponent(fileName, isDirectory: false)
            let data = try Data(contentsOf: source)
            try Self.atomicWrite(data, to: destination, forceFallback: false, fileManager: fileManager)
        }
    }

    // MARK: Pruning

    /// Deletes all but the `keepCount` most recent backups. Returns the
    /// backups that were removed.
    @discardableResult
    public func prune(keeping keepCount: Int) throws -> [Backup] {
        let backups = try listBackups() // newest first
        guard backups.count > keepCount else { return [] }
        let toRemove = Array(backups[keepCount...])
        let fileManager = FileManager.default
        for backup in toRemove {
            try fileManager.removeItem(at: backup.directoryURL)
        }
        return toRemove
    }

    // MARK: Atomic writes

    /// Writes `data` to `url` atomically: writes to a temp file in the
    /// same directory (so it's guaranteed to be on the same volume, which
    /// is required for a rename-based replace to be atomic at all), then
    /// swaps it into place.
    ///
    /// `FileManager.replaceItemAt` is the normal mechanism for this, but
    /// its semantics are documented against journaled, POSIX-permission
    /// filesystems — on FAT32 (what these devices actually use) it can fail in
    /// ways it wouldn't on APFS/HFS+. When that happens (or when
    /// `forceFallback` is passed, e.g. because the caller already knows
    /// it's targeting a FAT32 volume) this falls back to a plain
    /// remove-then-move, which is not atomic but is the best available
    /// primitive on that filesystem.
    public static func atomicWrite(_ data: Data, to url: URL, forceFallback: Bool = false) throws {
        try atomicWrite(data, to: url, forceFallback: forceFallback, fileManager: .default)
    }

    static func atomicWrite(_ data: Data, to url: URL, forceFallback: Bool, fileManager: FileManager) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent(".iopenpod-tmp-\(UUID().uuidString)", isDirectory: false)
        try data.write(to: tempURL, options: [])

        if !forceFallback {
            do {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
                AppleDoubleCleanup.strip(at: url)
                return
            } catch {
                // Fall through to the remove-then-move fallback below. If
                // replaceItemAt partially executed, tempURL may already be
                // gone; the fallback below tolerates that.
            }
        }

        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: tempURL, to: url)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }

        AppleDoubleCleanup.strip(at: url)
    }
}
