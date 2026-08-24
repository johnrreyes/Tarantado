import Foundation

/// Locates `golden-mini2g.itunesdb` directly in the source tree (rather than
/// via a bundled test resource, since `DAPSyncTests`'s target in
/// `Package.swift` — which this task must not modify — declares no
/// `resources:`). This is a real byte-for-byte copy of the iTunesDB from a
/// physical iPod mini 2nd gen, with 0 tracks, shared with `DAPDBTests`.
enum GoldenDatabase {
    static func url() throws -> URL {
        // This file lives at Tests/DAPSyncTests/Support/GoldenDatabase.swift.
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // DAPSyncTests
            .deletingLastPathComponent() // Tests
        let url = testsDirectory
            .appendingPathComponent("DAPDBTests", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("golden-mini2g.itunesdb", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    static func data() throws -> Data {
        try Data(contentsOf: try url())
    }
}
