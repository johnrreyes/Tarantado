import Foundation
import Testing
@testable import DAPDevice

@Suite struct DAPVolumeTests {
    @Test func validatesSyntheticVolumeAndResolvesModel() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }

        let volume = try DAPVolume.validate(at: root)
        #expect(volume.model.family == .mini)
        #expect(volume.model.requiresDatabaseSignature == .none)
        #expect(volume.sysInfo.modelNumber == "M9800")
    }

    @Test func pathAccessorsPointUnderTheVolume() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }

        let volume = try DAPVolume.validate(at: root)
        #expect(volume.iTunesDBURL.path == root.appendingPathComponent("iPod_Control/iTunes/iTunesDB").path)
        #expect(volume.iTunesPrefsURL.path == root.appendingPathComponent("iPod_Control/iTunes/iTunesPrefs").path)
        #expect(volume.iTunesPrefsPlistURL.path == root.appendingPathComponent("iPod_Control/iTunes/iTunesPrefs.plist").path)
        #expect(volume.playCountsURL.path == root.appendingPathComponent("iPod_Control/iTunes/Play Counts").path)
        #expect(volume.musicFolderURL(7).path == root.appendingPathComponent("iPod_Control/Music/F07").path)
        #expect(volume.musicFolderURL(49).path == root.appendingPathComponent("iPod_Control/Music/F49").path)
    }

    @Test func rejectsMissingDeviceDirectory() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("iPod_Control/Device"))

        #expect(throws: DAPVolume.ValidationError.self) {
            _ = try DAPVolume.validate(at: root)
        }
    }

    @Test func namesEveryMissingDirectoryInTheError() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("iPod_Control/Device"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("iPod_Control/iTunes"))

        do {
            _ = try DAPVolume.validate(at: root)
            Issue.record("expected validate(at:) to throw")
        } catch let DAPVolume.ValidationError.missingRequiredPaths(missing) {
            #expect(Set(missing) == ["iPod_Control/Device", "iPod_Control/iTunes"])
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectsCompletelyUnrelatedDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("NotAnDAP-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        #expect(throws: DAPVolume.ValidationError.self) {
            _ = try DAPVolume.validate(at: root)
        }
    }

    @Test func missingSysInfoIsNotAValidationFailure() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("iPod_Control/Device/SysInfo"))

        let volume = try DAPVolume.validate(at: root)
        #expect(volume.model.isUnknown == true)
        #expect(volume.sysInfo.raw.isEmpty)
    }

    @Test func capacityReadsSucceedOnATempVolume() throws {
        let root = try SyntheticDAP.make()
        defer { SyntheticDAP.remove(root) }

        let volume = try DAPVolume.validate(at: root)
        let capacity = try volume.capacity()
        #expect(capacity.totalBytes > 0)
        #expect(capacity.availableBytes >= 0)
    }

    @Test func withAccessAlwaysBalancesStopEvenOnThrow() {
        struct Boom: Error {}
        let url = FileManager.default.temporaryDirectory

        // Doesn't crash / leak: start-without-matching-stop would be a bug
        // we'd only see as flakiness elsewhere, but we can at least assert
        // the throw propagates correctly through the defer-guarded wrapper.
        #expect(throws: Boom.self) {
            try DAPVolume.withAccess(to: url) {
                throw Boom()
            }
        }

        let result = DAPVolume.withAccess(to: url) { 42 }
        #expect(result == 42)
    }

    // MARK: Real hardware (optional)

    @Test func realConnectedMini2GValidatesIfMounted() throws {
        let mountPoint = URL(fileURLWithPath: "/Volumes/JOHNREYES'S")
        guard FileManager.default.fileExists(atPath: mountPoint.path) else {
            // Not mounted on this machine: skip cleanly rather than fail.
            return
        }

        let volume = try DAPVolume.validate(at: mountPoint)
        #expect(volume.model.displayName == "iPod mini (2nd generation)")
        #expect(volume.model.family == .mini)
        #expect(volume.model.requiresDatabaseSignature == .none)
        #expect(volume.sysInfo.modelNumber == "M9800")
    }
}
