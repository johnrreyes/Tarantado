import Foundation
import Testing
@testable import DAPDevice

@Suite struct MusicFoldersTests {
    @Test func allocatesThousandsOfNamesWithNoCollisionsAndValidCharacterSet() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)
        let allocator = try MusicFolderAllocator(volume: volume)

        let validCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var seen = Set<String>()
        let count = 5000
        for _ in 0..<count {
            let allocated = try await allocator.allocate(fileExtension: "mp3")
            #expect(allocated.name.count == 4)
            #expect(allocated.name.unicodeScalars.allSatisfy { validCharacters.contains($0) })
            #expect(!seen.contains(allocated.name), "duplicate name allocated: \(allocated.name)")
            seen.insert(allocated.name)
        }
        #expect(seen.count == count)
    }

    @Test func distributesAllocationsEvenlyAcrossFolders() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)
        let allocator = try MusicFolderAllocator(volume: volume)

        let count = 5000
        for _ in 0..<count {
            _ = try await allocator.allocate(fileExtension: "mp3")
        }

        let counts = await allocator.folderCounts()
        #expect(counts.count == 50)
        #expect(counts.reduce(0, +) == count)
        let minCount = counts.min()!
        let maxCount = counts.max()!
        // Perfectly even would be 100 per folder; allow a little slack.
        #expect(maxCount - minCount <= 1)
    }

    @Test func neverReturnsANameThatAlreadyExistsOnDisk() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)

        // Pre-populate F00 with some existing filenames before the
        // allocator ever scans the volume.
        let preexisting = ["ABCD.mp3", "WXYZ.m4a", "AAAA.mp3"]
        for name in preexisting {
            let path = volume.musicFolderURL(0).appendingPathComponent(name)
            try Data().write(to: path)
        }

        let allocator = try MusicFolderAllocator(volume: volume)
        var allocatedNames = Set<String>()
        for _ in 0..<2000 {
            let allocated = try await allocator.allocate(fileExtension: "mp3")
            allocatedNames.insert(allocated.name)
        }

        #expect(!allocatedNames.contains("ABCD"))
        #expect(!allocatedNames.contains("WXYZ"))
        #expect(!allocatedNames.contains("AAAA"))
    }

    @Test func allocatedFilesLandInsideTheirReportedFolder() async throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)
        let allocator = try MusicFolderAllocator(volume: volume)

        let allocated = try await allocator.allocate(fileExtension: "mp3")
        let expectedFolder = volume.musicFolderURL(allocated.folderIndex)
        #expect(allocated.url.deletingLastPathComponent().path == expectedFolder.path)
        #expect(allocated.url.lastPathComponent == "\(allocated.name).mp3")
    }

    @Test func iPodPathRoundTripsThroughURL() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)

        let url = volume.musicFolderURL(7).appendingPathComponent("ABCD.mp3")
        let path = DAPPath.iPodPath(for: url, relativeTo: volume)
        #expect(path == ":iPod_Control:Music:F07:ABCD.mp3")

        let roundTrippedURL = DAPPath.url(forDAPPath: path!, relativeTo: volume)
        #expect(roundTrippedURL.standardizedFileURL.path == url.standardizedFileURL.path)
    }

    @Test func iPodPathReturnsNilForURLOutsideVolume() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        let volume = try DAPVolume.validate(at: root)

        let outsideURL = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere.mp3")
        #expect(DAPPath.iPodPath(for: outsideURL, relativeTo: volume) == nil)
    }
}
