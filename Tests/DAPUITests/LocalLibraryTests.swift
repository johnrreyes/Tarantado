import Foundation
import Testing
@testable import DAPUI

@Suite struct LocalLibraryTests {
    private func makeLibrary() throws -> (LocalLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LocalLibrary(folderURL: root), root)
    }

    private func makeSourceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    /// Paths are resolved on both sides before comparing: the temporary
    /// directory is reached through the /var → /private/var symlink, and the
    /// enumerator hands back the resolved form.
    private func names(in root: URL) -> [String] {
        let base = root.resolvingSymlinksInPath().path + "/"
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var found: [String] = []
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            found.append(url.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: ""))
        }
        return found.sorted()
    }

    // MARK: - Importing

    @Test func importsLooseFilesAndIgnoresNonAudio() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: source) }

        try write(10, to: source.appendingPathComponent("a.mp3"))
        try write(10, to: source.appendingPathComponent("cover.jpg"))

        let summary = try library.importItems(from: [
            source.appendingPathComponent("a.mp3"),
            source.appendingPathComponent("cover.jpg"),
        ])

        #expect(summary.imported.count == 1)
        #expect(summary.failures.isEmpty)
        #expect(names(in: root) == ["a.mp3"])
    }

    /// Two albums can easily both contain `01.mp3`. Importing a folder keeps
    /// its name, so the second one doesn't overwrite the first.
    @Test func importingAFolderPreservesItsStructure() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: source) }

        let albumOne = source.appendingPathComponent("Album One", isDirectory: true)
        let albumTwo = source.appendingPathComponent("Album Two", isDirectory: true)
        try write(10, to: albumOne.appendingPathComponent("01.mp3"))
        try write(20, to: albumTwo.appendingPathComponent("01.mp3"))

        let summary = try library.importItems(from: [albumOne, albumTwo])
        #expect(summary.imported.count == 2)

        let found = names(in: root)
        #expect(found == ["Album One/01.mp3", "Album Two/01.mp3"])
    }

    @Test func reimportingIdenticalFilesSkipsRatherThanDuplicating() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: source) }

        let file = source.appendingPathComponent("a.mp3")
        try write(10, to: file)

        _ = try library.importItems(from: [file])
        let second = try library.importItems(from: [file])

        #expect(second.imported.isEmpty)
        #expect(second.skipped == ["a.mp3"])
        #expect(names(in: root) == ["a.mp3"])
    }

    /// Same name, different bytes is genuinely ambiguous — a different rip of
    /// the same track, say. Keeping both is recoverable; silently picking one
    /// is not.
    @Test func sameNameDifferentContentKeepsBoth() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: source) }

        let file = source.appendingPathComponent("a.mp3")
        try write(10, to: file)
        _ = try library.importItems(from: [file])

        try write(999, to: file)
        let second = try library.importItems(from: [file])

        #expect(second.imported.count == 1)
        #expect(second.skipped.isEmpty)
        #expect(names(in: root) == ["a 2.mp3", "a.mp3"])
    }

    @Test func aFolderWithNoAudioLeavesNoEmptyDirectory() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: source) }

        let photos = source.appendingPathComponent("Photos", isDirectory: true)
        try write(10, to: photos.appendingPathComponent("a.jpg"))

        let summary = try library.importItems(from: [photos])
        #expect(summary.imported.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Photos").path))
    }

    @Test func reportsAFailureForAMissingItemWithoutAbandoningTheRest() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: source) }

        try write(10, to: source.appendingPathComponent("good.mp3"))

        let summary = try library.importItems(from: [
            source.appendingPathComponent("gone.mp3"),
            source.appendingPathComponent("good.mp3"),
        ])

        #expect(summary.failures.count == 1)
        #expect(summary.failures.first?.name == "gone.mp3")
        #expect(summary.imported.count == 1)
    }

    // MARK: - Removing

    @Test func removingTheLastTrackInAnAlbumPrunesTheFolder() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: source) }

        let album = source.appendingPathComponent("Album", isDirectory: true)
        try write(10, to: album.appendingPathComponent("01.mp3"))
        try write(10, to: album.appendingPathComponent("02.mp3"))
        _ = try library.importItems(from: [album])

        let imported = root.appendingPathComponent("Album")
        try library.remove([imported.appendingPathComponent("01.mp3")])
        #expect(FileManager.default.fileExists(atPath: imported.path))

        try library.remove([imported.appendingPathComponent("02.mp3")])
        #expect(!FileManager.default.fileExists(atPath: imported.path))
        // The library root itself must survive being emptied.
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    /// The library only ever deletes its own files. A path outside it — which
    /// could only arrive through a bug — is ignored rather than obeyed.
    @Test func refusesToRemoveAnythingOutsideTheLibrary() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: source) }

        let outside = source.appendingPathComponent("precious.mp3")
        try write(10, to: outside)

        try library.remove([outside])
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func totalBytesCountsEverythingImported() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceDir()
        defer { try? FileManager.default.removeItem(at: source) }

        try write(100, to: source.appendingPathComponent("a.mp3"))
        try write(250, to: source.appendingPathComponent("b.mp3"))
        _ = try library.importItems(from: [
            source.appendingPathComponent("a.mp3"),
            source.appendingPathComponent("b.mp3"),
        ])

        #expect(library.totalBytes() == 350)
    }
}
