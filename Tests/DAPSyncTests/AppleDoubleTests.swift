import Foundation
import Testing
@testable import DAPSync

/// iPods are FAT32, which cannot store extended attributes natively, so macOS
/// materializes any xattr as a companion `._NAME` file. Recent macOS releases
/// tag written files with `com.apple.provenance` on their own, which was enough
/// to leave a 4 KB `._FUOR.mp3` beside every track copied to a real iPod.
struct AppleDoubleTests {
    @Test func stripsExtendedAttributesFromACopiedFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("FUOR.mp3")
        try Data("audio".utf8).write(to: file)

        try file.withUnsafeFileSystemRepresentation { path in
            let value = Array("x".utf8)
            #expect(setxattr(path, "com.example.test", value, value.count, 0, 0) == 0)
        }

        SyncEngine.stripAppleDoubleArtifacts(at: file)

        // `com.apple.provenance` is applied by macOS itself and is
        // system-protected: even `xattr -c` cannot remove it. So we assert we
        // removed everything removable, not that the list is empty.
        var names = [CChar](repeating: 0, count: 4096)
        let size = file.withUnsafeFileSystemRepresentation { listxattr($0, &names, 4096, 0) }
        let remaining = names.prefix(max(size, 0))
            .split(separator: 0)
            .map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }

        #expect(!remaining.contains("com.example.test"))
        #expect(remaining.allSatisfy { $0 == "com.apple.provenance" })
        #expect(FileManager.default.contents(atPath: file.path) == Data("audio".utf8))
    }

    @Test func deletesTheAppleDoubleSidecarNextToTheFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("FUOR.mp3")
        let sidecar = dir.appendingPathComponent("._FUOR.mp3")
        try Data("audio".utf8).write(to: file)
        try Data(repeating: 0, count: 4096).write(to: sidecar)

        SyncEngine.stripAppleDoubleArtifacts(at: file)

        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
