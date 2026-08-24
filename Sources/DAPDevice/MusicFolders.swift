import Foundation

/// Converts between the colon-delimited path strings the classic iPod
/// database (iTunesDB) stores for each track, and real filesystem `URL`s
/// under an `DAPVolume`.
///
/// iTunesDB paths are volume-relative and colon-delimited, e.g.
/// `:iPod_Control:Music:F07:ABCD.mp3`.
public enum DAPPath {
    /// Converts an iTunesDB-style path (relative to the volume root) into
    /// a real `URL` under `volume`.
    public static func url(forDAPPath path: String, relativeTo volume: DAPVolume) -> URL {
        let components = path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        var url = volume.rootURL
        for component in components {
            url.appendPathComponent(component)
        }
        return url
    }

    /// Converts a real `URL` under `volume` into its iTunesDB-style,
    /// colon-delimited, volume-relative path. Returns `nil` if `url` isn't
    /// inside `volume.rootURL`.
    public static func iPodPath(for url: URL, relativeTo volume: DAPVolume) -> String? {
        let rootPath = volume.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let targetPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else { return nil }
        var relative = String(targetPath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        guard !relative.isEmpty else { return nil }
        let components = relative.split(separator: "/").map(String.init)
        return ":" + components.joined(separator: ":")
    }
}

/// Allocates unique, FAT32/DOS-8.3-safe filenames for new music files, and
/// spreads them evenly across a device's `F00`...`F<N-1>` music folders.
///
/// Names are 4 uppercase ASCII letters (`A`-`Z`), which combined with a
/// 3-character extension always fits the 8.3 short-name limit and every
/// character is valid in a FAT32 short name (no spaces, no punctuation,
/// no lowercase — lowercase 8.3 names get case-folded by some
/// implementations, so we avoid the ambiguity entirely).
///
/// This is an `actor` because allocation mutates shared in-memory state
/// (per-folder counts, the used-name set) and must be safe to call from
/// concurrent sync tasks without callers hand-rolling their own locking.
public actor MusicFolderAllocator {
    public struct AllocatedFile: Sendable, Equatable {
        /// Index of the `F<NN>` folder this file was placed in.
        public let folderIndex: Int
        /// The 4-letter uppercase stem, e.g. `"ABCD"`.
        public let name: String
        /// Extension as supplied by the caller (case preserved), e.g. `"mp3"`.
        public let fileExtension: String
        /// Real filesystem location.
        public let url: URL
        /// iTunesDB-style colon-delimited path, e.g.
        /// `:iPod_Control:Music:F07:ABCD.mp3`.
        public let iPodPath: String
    }

    public enum AllocationError: Error, LocalizedError, Equatable {
        case namespaceExhausted
        case noMusicFolders

        public var errorDescription: String? {
            switch self {
            case .namespaceExhausted:
                return "All possible 4-letter filenames are already in use on this device."
            case .noMusicFolders:
                return "This device reports zero music folders; can't allocate a filename."
            }
        }
    }

    /// Size of the 4-letter `A`-`Z` namespace: 26^4.
    static let nameSpaceSize: UInt32 = 26 * 26 * 26 * 26

    private let volume: DAPVolume
    private let folderCount: Int
    private var counts: [Int]
    private var usedNames: Set<String>
    private var cursor: UInt32

    /// Scans each existing music folder's contents once (synchronously) to
    /// seed per-folder counts and the set of names already in use, so
    /// allocation can never return a name that collides with something
    /// already on disk.
    public init(volume: DAPVolume) throws {
        self.volume = volume
        let folderCount = volume.model.musicFolderCount
        guard folderCount > 0 else { throw AllocationError.noMusicFolders }
        self.folderCount = folderCount

        var counts = [Int](repeating: 0, count: folderCount)
        var used = Set<String>()
        let fileManager = FileManager.default
        for index in 0..<folderCount {
            let folderURL = volume.musicFolderURL(index)
            let contents = (try? fileManager.contentsOfDirectory(atPath: folderURL.path)) ?? []
            counts[index] = contents.count
            for entry in contents {
                let stem = (entry as NSString).deletingPathExtension.uppercased()
                if stem.count == 4 {
                    used.insert(stem)
                }
            }
        }
        self.counts = counts
        self.usedNames = used
        // Randomize the starting point so successive syncs of the same
        // device don't always begin allocating from "AAAA".
        self.cursor = UInt32.random(in: 0..<Self.nameSpaceSize)
    }

    /// Allocates a new unique filename in the currently least-populated
    /// music folder. Does not create the file on disk — callers write the
    /// actual audio data to `AllocatedFile.url` themselves.
    public func allocate(fileExtension: String) throws -> AllocatedFile {
        guard let folderIndex = leastPopulatedFolderIndex() else {
            throw AllocationError.noMusicFolders
        }
        let name = try nextUnusedName()
        counts[folderIndex] += 1

        let fileName = "\(name).\(fileExtension)"
        let url = volume.musicFolderURL(folderIndex).appendingPathComponent(fileName, isDirectory: false)
        let iPodPath = DAPPath.iPodPath(for: url, relativeTo: volume) ?? ":iPod_Control:Music:\(DAPVolume.folderName(for: folderIndex)):\(fileName)"

        return AllocatedFile(
            folderIndex: folderIndex,
            name: name,
            fileExtension: fileExtension,
            url: url,
            iPodPath: iPodPath
        )
    }

    /// Current file counts per folder, for tests/diagnostics.
    public func folderCounts() -> [Int] {
        counts
    }

    private func leastPopulatedFolderIndex() -> Int? {
        guard !counts.isEmpty else { return nil }
        var bestIndex = 0
        var bestCount = counts[0]
        for index in 1..<counts.count where counts[index] < bestCount {
            bestIndex = index
            bestCount = counts[index]
        }
        return bestIndex
    }

    private func nextUnusedName() throws -> String {
        guard usedNames.count < Int(Self.nameSpaceSize) else {
            throw AllocationError.namespaceExhausted
        }
        for _ in 0..<Self.nameSpaceSize {
            let candidate = Self.name(for: cursor)
            cursor = (cursor + 1) % Self.nameSpaceSize
            if usedNames.insert(candidate).inserted {
                return candidate
            }
        }
        throw AllocationError.namespaceExhausted
    }

    /// Maps `0..<26^4` bijectively onto 4-letter `A`-`Z` strings (base-26).
    static func name(for value: UInt32) -> String {
        var remainder = value
        var scalars = [Unicode.Scalar]()
        scalars.reserveCapacity(4)
        for _ in 0..<4 {
            let letterIndex = Int(remainder % 26)
            scalars.append(Unicode.Scalar(UInt8(65 + letterIndex)))
            remainder /= 26
        }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }
}
