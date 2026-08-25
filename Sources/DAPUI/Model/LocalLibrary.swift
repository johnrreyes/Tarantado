import Foundation
import DAPDevice
import DAPSync

/// A folder inside the app's own container that holds music the user has
/// staged for syncing.
///
/// On iPhone and iPad there is no general-purpose filesystem to scan: the
/// document picker hands out one-shot, security-scoped URLs that stop being
/// readable once the picker's scope ends, so "remember this folder and scan
/// it again later" is not a thing the platform offers. Copying the files in
/// once, into a folder the app owns outright, is what makes a persistent
/// library possible at all. The same store is used on macOS so there is a
/// single code path, though macOS additionally keeps the option of scanning
/// an external folder in place (see `AppModel.useExternalFolder`).
///
/// The folder lives in Documents deliberately: with `UIFileSharingEnabled`
/// that makes it visible in the Files app, so the user can also drag music
/// in from another app, or get their files back out, without the app having
/// to implement either.
public struct LocalLibrary: Sendable {
    public let folderURL: URL

    public init(folderURL: URL) {
        self.folderURL = folderURL
    }

    /// The library folder in the app container, created if needed.
    public static func makeDefault() throws -> LocalLibrary {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = documents.appendingPathComponent("Local Library", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return LocalLibrary(folderURL: folder)
    }

    // MARK: - Importing

    public struct ImportFailure: Sendable, Equatable {
        public let name: String
        public let message: String
    }

    public struct ImportSummary: Sendable, Equatable {
        public var imported: [URL] = []
        /// Files already present in the library, by name. Re-importing the
        /// same album is a normal thing to do by accident, so it is reported
        /// rather than treated as an error.
        public var skipped: [String] = []
        /// Picked items that already live inside the library folder, by
        /// name — most often the library folder itself. Distinct from
        /// `skipped`, which is about a file of the same name already being
        /// there: this is "you pointed the importer at the library", which
        /// needs a different sentence to be understood.
        public var alreadyInLibrary: [String] = []
        public var failures: [ImportFailure] = []

        public var isEmpty: Bool {
            imported.isEmpty && skipped.isEmpty && alreadyInLibrary.isEmpty && failures.isEmpty
        }
    }

    /// True when `url` is the library folder itself or anything inside it.
    ///
    /// Both sides are resolved first: `/var` and `/private/var` name the
    /// same directory through a symlink, and the document picker is free to
    /// hand back either form.
    func isInsideLibrary(_ url: URL) -> Bool {
        let root = folderURL.resolvingSymlinksInPath().path
        let candidate = url.resolvingSymlinksInPath().path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    /// Copies audio files from `urls` into the library. Each URL may be a
    /// file or a folder; a folder is copied as a subfolder of the same name,
    /// so albums stay grouped and two tracks called `01.mp3` from different
    /// albums don't collide.
    ///
    /// Picked URLs are security-scoped, and the scope has to be held for the
    /// whole recursive walk, not just the top-level call.
    ///
    /// Items that already live inside the library are reported, not copied —
    /// see `alreadyInLibrary`.
    public func importItems(from urls: [URL]) throws -> ImportSummary {
        var summary = ImportSummary()
        for url in urls {
            // Importing the library into itself copies every file one level
            // deeper — `Local Library/Local Library/...` — and the scanner
            // then finds both copies and reports every track twice. The
            // files are already in the library by definition, so there is
            // nothing to do but say so.
            //
            // This is reachable in normal use: with `UIFileSharingEnabled`
            // the library folder shows up in the Files app, so "Add Folder"
            // can be pointed straight at it.
            guard !isInsideLibrary(url) else {
                summary.alreadyInLibrary.append(url.lastPathComponent)
                continue
            }
            do {
                try DAPVolume.withAccess(to: url) {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    if isDirectory.boolValue {
                        try importFolder(url, into: uniqueSubfolder(named: url.lastPathComponent), summary: &summary)
                    } else {
                        try importFile(url, into: folderURL, summary: &summary)
                    }
                }
            } catch {
                summary.failures.append(ImportFailure(name: url.lastPathComponent, message: SyncEngine.describe(error)))
            }
        }
        return summary
    }

    private func importFolder(_ source: URL, into destination: URL, summary: inout ImportSummary) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        // Only create the destination once we know there is something worth
        // putting in it, so a folder of photos doesn't leave an empty shell.
        var created = false
        for child in contents {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                try importFolder(child, into: destination.appendingPathComponent(child.lastPathComponent, isDirectory: true), summary: &summary)
                continue
            }
            guard LibraryScanner.candidateExtensions.contains(child.pathExtension.lowercased()) else { continue }
            if !created {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                created = true
            }
            try importFile(child, into: destination, summary: &summary)
        }
    }

    private func importFile(_ source: URL, into destination: URL, summary: inout ImportSummary) throws {
        guard LibraryScanner.candidateExtensions.contains(source.pathExtension.lowercased()) else { return }
        let target = destination.appendingPathComponent(source.lastPathComponent)

        if FileManager.default.fileExists(atPath: target.path) {
            let existing = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let incoming = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
            if existing == incoming {
                summary.skipped.append(source.lastPathComponent)
                return
            }
            // Same name, different bytes: keep both rather than guessing
            // which one the user meant.
            let unique = uniqueName(for: source.lastPathComponent, in: destination)
            try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(unique))
            summary.imported.append(destination.appendingPathComponent(unique))
            return
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        summary.imported.append(target)
    }

    private func uniqueSubfolder(named name: String) -> URL {
        folderURL.appendingPathComponent(name, isDirectory: true)
    }

    private func uniqueName(for name: String, in directory: URL) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            index += 1
        }
    }

    // MARK: - Removing

    /// Deletes files from the library. Removing the last track in an album
    /// subfolder takes the now-empty folder with it, so the library doesn't
    /// silt up with empty directories.
    public func remove(_ urls: [URL]) throws {
        // Both sides are resolved before comparing: /var and /private/var
        // name the same directory through a symlink, and a raw string prefix
        // test would quietly refuse to delete perfectly valid library files
        // depending only on which form the URL arrived in.
        let root = folderURL.resolvingSymlinksInPath().path
        for url in urls {
            guard url.resolvingSymlinksInPath().path.hasPrefix(root) else { continue }
            try FileManager.default.removeItem(at: url)
            pruneEmptyDirectories(from: url.deletingLastPathComponent())
        }
    }

    private func pruneEmptyDirectories(from directory: URL) {
        let root = folderURL.resolvingSymlinksInPath().path
        var current = directory
        while current.resolvingSymlinksInPath().path.hasPrefix(root),
              current.resolvingSymlinksInPath().path != root {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path)
            guard let contents, contents.isEmpty else { return }
            try? FileManager.default.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }

    /// Total bytes held by the library, for display.
    public func totalBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
