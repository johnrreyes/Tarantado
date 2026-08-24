import Foundation

/// A validated, mounted classic-iPod volume: the root of a FAT32 (or
/// HFS+, on very old devices) filesystem containing an `iPod_Control`
/// directory tree.
///
/// Construct one with `DAPVolume.validate(at:)`. That both confirms the
/// on-disk layout looks like an iPod and resolves the device's identity
/// (`sysInfo`, `model`) up front, so downstream code never has to
/// re-validate.
public struct DAPVolume: Sendable, Equatable {
    /// The mount point / root of the volume, e.g. `file:///Volumes/MYIPOD/`.
    public let rootURL: URL

    /// Parsed `iPod_Control/Device/SysInfo`. Empty (all fields nil) if the
    /// file was missing or unreadable — see `validate(at:)`.
    public let sysInfo: SysInfo

    /// The identified device model and its capability flags.
    public let model: DeviceModel

    public init(rootURL: URL, sysInfo: SysInfo, model: DeviceModel) {
        self.rootURL = rootURL
        self.sysInfo = sysInfo
        self.model = model
    }

    // MARK: Validation

    /// Describes why `at` doesn't look like a valid iPod volume.
    public enum ValidationError: Error, LocalizedError, Equatable {
        /// `at` exists but isn't a directory.
        case notADirectory(URL)

        /// One or more of the three required `iPod_Control` subdirectories
        /// is missing. Paths are volume-relative, e.g.
        /// `"iPod_Control/iTunes"`.
        case missingRequiredPaths([String])

        public var errorDescription: String? {
            switch self {
            case .notADirectory(let url):
                return "\(url.path) is not a directory."
            case .missingRequiredPaths(let paths):
                return "This doesn't look like a DAP (missing \(paths.joined(separator: ", "))). " +
                    "It may be a plain USB drive rather than an iPod, or the iPod_Control folder may be hidden."
            }
        }
    }

    /// Confirms `iPod_Control/Device`, `iPod_Control/iTunes`, and
    /// `iPod_Control/Music` all exist under `url`, then parses `SysInfo`
    /// and resolves the `DeviceModel`.
    ///
    /// A missing or unreadable `SysInfo` file is *not* treated as a
    /// validation failure (some recovery/repair flows want to validate a
    /// volume before SysInfo exists or while it's corrupt) — in that case
    /// `sysInfo` is empty and `model` resolves to `.unknown`.
    ///
    /// This does not itself manage security-scoped access; wrap the call
    /// in `DAPVolume.withAccess(to:_:)` when `url` came from a document
    /// picker.
    public static func validate(at url: URL) throws -> DAPVolume {
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ValidationError.missingRequiredPaths(requiredRelativePaths)
        }
        guard isDirectory.boolValue else {
            throw ValidationError.notADirectory(url)
        }

        var missing: [String] = []
        for relativePath in requiredRelativePaths {
            let candidate = url.appendingPathComponent(relativePath, isDirectory: true)
            var candidateIsDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: candidate.path, isDirectory: &candidateIsDirectory)
            if !exists || !candidateIsDirectory.boolValue {
                missing.append(relativePath)
            }
        }
        guard missing.isEmpty else {
            throw ValidationError.missingRequiredPaths(missing)
        }

        let deviceDirectory = url
            .appendingPathComponent("iPod_Control", isDirectory: true)
            .appendingPathComponent("Device", isDirectory: true)
        let sysInfoURL = deviceDirectory
            .appendingPathComponent("SysInfo", isDirectory: false)
        let extendedURL = deviceDirectory
            .appendingPathComponent("SysInfoExtended", isDirectory: false)

        // Prefer the plain-text SysInfo the device wrote itself, but fall
        // back to (and fill gaps from) the SysInfoExtended plist that newer
        // iTunes versions write in its place. A device carrying only the
        // latter used to identify as "Unknown iPod" with an unknown serial,
        // which the app then refused to sync.
        var sysInfo = (try? SysInfo(contentsOf: sysInfoURL)) ?? SysInfo(raw: [:])
        if let extended = SysInfo(sysInfoExtendedContentsOf: extendedURL) {
            sysInfo = sysInfo.merging(extended)
        }
        let model = DeviceModel.resolve(from: sysInfo)

        return DAPVolume(rootURL: url, sysInfo: sysInfo, model: model)
    }

    private static let requiredRelativePaths = [
        "iPod_Control/Device",
        "iPod_Control/iTunes",
        "iPod_Control/Music",
    ]

    /// Every identifying field we read off the device, as shareable plain
    /// text.
    ///
    /// When a device resolves to `.unknown` the only way forward is a new
    /// entry in `DeviceModel`'s table, and the only person who can supply
    /// the model number is whoever is holding the iPod. So the app has to
    /// be able to hand it over — a screenshot of "Unknown iPod" is not
    /// enough to act on.
    public var identityReport: String {
        let header = "Tarantado device identity\nResolved model: \(model.displayName) (\(model.generation))"
        guard !sysInfo.raw.isEmpty else {
            return header + "\n\nNo SysInfo or SysInfoExtended found on this device."
        }
        let fields = sysInfo.raw
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        return header + "\n\n" + fields
    }

    // MARK: Path accessors

    public var controlDirectory: URL {
        rootURL.appendingPathComponent("iPod_Control", isDirectory: true)
    }

    public var deviceDirectory: URL {
        controlDirectory.appendingPathComponent("Device", isDirectory: true)
    }

    public var iTunesDirectory: URL {
        controlDirectory.appendingPathComponent("iTunes", isDirectory: true)
    }

    public var musicDirectory: URL {
        controlDirectory.appendingPathComponent("Music", isDirectory: true)
    }

    public var sysInfoURL: URL {
        deviceDirectory.appendingPathComponent("SysInfo", isDirectory: false)
    }

    public var iTunesDBURL: URL {
        iTunesDirectory.appendingPathComponent("iTunesDB", isDirectory: false)
    }

    public var iTunesPrefsURL: URL {
        iTunesDirectory.appendingPathComponent("iTunesPrefs", isDirectory: false)
    }

    public var iTunesPrefsPlistURL: URL {
        iTunesDirectory.appendingPathComponent("iTunesPrefs.plist", isDirectory: false)
    }

    public var playCountsURL: URL {
        iTunesDirectory.appendingPathComponent("Play Counts", isDirectory: false)
    }

    /// URL of music folder `index`, e.g. `musicFolderURL(7)` ->
    /// `iPod_Control/Music/F07`. Does not validate `index` against
    /// `model.musicFolderCount`.
    public func musicFolderURL(_ index: Int) -> URL {
        musicDirectory.appendingPathComponent(Self.folderName(for: index), isDirectory: true)
    }

    static func folderName(for index: Int) -> String {
        String(format: "F%02d", index)
    }

    // MARK: Capacity

    public struct Capacity: Sendable, Equatable {
        public let totalBytes: Int64
        public let availableBytes: Int64

        public init(totalBytes: Int64, availableBytes: Int64) {
            self.totalBytes = totalBytes
            self.availableBytes = availableBytes
        }
    }

    /// Reads volume capacity via `URLResourceValues`.
    ///
    /// `volumeAvailableCapacityForImportantUsage` is normally the more honest
    /// number to show a user, because it accounts for space the system
    /// considers purgeable. But it is only meaningful on volumes the system
    /// manages that way: on a **FAT32 USB volume — i.e. every classic iPod —
    /// it returns 0 even when the disk is nearly empty.** Measured against a
    /// physical iPod mini 2G: `importantUsage` = 0 while the plain available
    /// key correctly reported 23,105,454,080 bytes free of 32,171,130,880.
    ///
    /// Trusting it blindly would make every sync fail the free-space check on
    /// real hardware, so fall back to the plain key whenever it is nil or 0.
    public func capacity() throws -> Capacity {
        let values = try rootURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = values.volumeTotalCapacity ?? 0

        let importantUsage = values.volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64(values.volumeAvailableCapacity ?? 0)
        let available = importantUsage > 0 ? importantUsage : plain

        return Capacity(totalBytes: Int64(total), availableBytes: available)
    }

    // MARK: Security-scoped access

    /// Runs `body` while `url`'s security-scoped access is active,
    /// guaranteeing the matching `stopAccessingSecurityScopedResource()`
    /// call happens exactly once, even if `body` throws.
    ///
    /// On URLs that aren't security-scoped (e.g. macOS paths not obtained
    /// from a picker or bookmark), `startAccessingSecurityScopedResource()`
    /// is a harmless no-op that returns `false`, so this is safe to wrap
    /// around every volume access unconditionally.
    public static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body()
    }

    /// Async variant of `withAccess(to:_:)`.
    public static func withAccess<T>(to url: URL, _ body: () async throws -> T) async rethrows -> T {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await body()
    }

    // MARK: Bookmarks
    //
    // IMPORTANT: on iOS, a security-scoped bookmark for a removable/USB
    // volume (which is how a mounted iPod is exposed via the document
    // picker) does NOT reliably resolve after the volume is remounted —
    // unplugging and replugging the iPod, plugging into a different port,
    // or a Files-app re-enumeration can all change the underlying volume
    // identity enough that resolution fails or `isStale` comes back true.
    // Callers must treat bookmark resolution as best-effort and be ready
    // to fall back to re-presenting a document picker; do not rely on a
    // saved bookmark alone to "remember" an iPod across app launches.

    /// Creates a bookmark for `url` suitable for persisting across
    /// launches. Must be called while `url`'s security scope is active
    /// (i.e. from inside `withAccess(to:_:)`) when `url` is security-scoped.
    public static func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        return try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
    }

    public struct ResolvedBookmark: Sendable {
        public let url: URL
        public let isStale: Bool
    }

    /// Resolves a bookmark created by `makeBookmark(for:)`. See the note
    /// above: on iOS this can fail, or succeed with `isStale == true`,
    /// after the volume has been remounted. Callers should re-validate the
    /// resolved URL with `validate(at:)` and fall back to re-picking on
    /// failure rather than surfacing a raw error.
    public static func resolveBookmark(_ data: Data) throws -> ResolvedBookmark {
        var isStale = false
        #if os(macOS)
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #else
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #endif
        return ResolvedBookmark(url: url, isStale: isStale)
    }
}
