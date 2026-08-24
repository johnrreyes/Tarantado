import Foundation
import Testing
@testable import DAPDevice

@Suite struct SysInfoTests {
    @Test func parsesBundledSampleFile() throws {
        let sysInfo = try SysInfo(contentsOf: SyntheticDAP.sampleSysInfoURL)

        #expect(sysInfo.boardHwName == "iPod Q22B")
        #expect(sysInfo.serialNumber == "EXAMPLE0001")
        #expect(sysInfo.modelNumber == "M9800")
        #expect(sysInfo.firewireGUID == 0x000A270000000001)
        #expect(sysInfo.iPodFamily == 3)
        #expect(sysInfo.visibleBuildIDHex == 0x01418000)
        #expect(sysInfo.visibleBuildIDVersion == "1.4.1")

        // Unrecognized keys should still be reachable via the raw table.
        #expect(sysInfo.raw["HddFirmwareRev"] == "Rev 3.72")
        #expect(sysInfo.raw["RegionCode"] == "LL(0x0001)")
    }

    @Test func toleratesCRLFLineEndings() {
        let text = "BoardHwName: iPod Q22B\r\npszSerialNumber: ABC123\r\nModelNumStr: M9800\r\n"
        let sysInfo = SysInfo(parsing: text)
        #expect(sysInfo.boardHwName == "iPod Q22B")
        #expect(sysInfo.serialNumber == "ABC123")
        #expect(sysInfo.modelNumber == "M9800")
    }

    @Test func toleratesExtraWhitespaceAndTrailingBlankLines() {
        let text = "  BoardHwName :   iPod Q22B  \n\nModelNumStr:M9800\n\n\n"
        let sysInfo = SysInfo(parsing: text)
        #expect(sysInfo.boardHwName == "iPod Q22B")
        #expect(sysInfo.modelNumber == "M9800")
    }

    @Test func toleratesMissingKeys() {
        let sysInfo = SysInfo(parsing: "ModelNumStr: M9800\n")
        #expect(sysInfo.modelNumber == "M9800")
        #expect(sysInfo.serialNumber == nil)
        #expect(sysInfo.firewireGUID == nil)
        #expect(sysInfo.iPodFamily == nil)
        #expect(sysInfo.visibleBuildIDHex == nil)
        #expect(sysInfo.visibleBuildIDVersion == nil)
    }

    @Test func toleratesUnknownKeysAndMalformedLines() {
        let text = """
        ModelNumStr: M9800
        SomeFutureField: whatever
        this line has no colon
        : emptykey
        """
        let sysInfo = SysInfo(parsing: text)
        #expect(sysInfo.modelNumber == "M9800")
        #expect(sysInfo.raw["SomeFutureField"] == "whatever")
        #expect(sysInfo.raw.count == 2) // malformed lines are skipped
    }

    @Test func emptyStringParsesToEmptySysInfo() {
        let sysInfo = SysInfo(parsing: "")
        #expect(sysInfo.raw.isEmpty)
        #expect(sysInfo.modelNumber == nil)
    }
}

/// `SysInfoExtended` is the XML property list newer iTunes versions write
/// in place of the plain-text `SysInfo`. A device carrying only that file
/// used to read back with every identifying field empty.
@Suite struct SysInfoExtendedTests {
    /// Shaped like the real file: `x`-prefixed order number, GUID as a bare
    /// hex string with no `0x`, family and build IDs as integers.
    static func plist(modelNumber: String = "xMA448LL", familyID: Int = 19) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ModelNumStr</key><string>\(modelNumber)</string>
            <key>SerialNumber</key><string>5A6420ABVR0</string>
            <key>BoardHwName</key><string>iPod Q41</string>
            <key>FirewireGuid</key><string>000A27001A2B3C4D</string>
            <key>FamilyID</key><integer>\(familyID)</integer>
            <key>UpdaterFamilyID</key><integer>19</integer>
            <key>VisibleBuildID</key><integer>21430272</integer>
        </dict>
        </plist>
        """
    }

    @Test func parsesTheExtendedPlistIntoSysInfoKeys() throws {
        let sysInfo = try #require(SysInfo(sysInfoExtended: Data(Self.plist().utf8)))

        #expect(sysInfo.modelNumber == "xMA448LL")
        #expect(sysInfo.normalizedModelNumber == "MA448")
        #expect(sysInfo.serialNumber == "5A6420ABVR0")
        #expect(sysInfo.boardHwName == "iPod Q41")
        // A bare hex GUID must not be misread as a decimal number.
        #expect(sysInfo.firewireGUID == 0x000A27001A2B3C4D)
        #expect(sysInfo.iPodFamily == 19)
        #expect(sysInfo.visibleBuildIDHex == 21_430_272)
    }

    @Test func rejectsFilesThatArentAUsablePlist() {
        #expect(SysInfo(sysInfoExtended: Data("not a plist".utf8)) == nil)
        // A well-formed plist with none of the keys we care about is no
        // more useful than a missing file.
        let empty = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Unrelated</key><string>x</string></dict></plist>
        """
        #expect(SysInfo(sysInfoExtended: Data(empty.utf8)) == nil)
    }

    @Test func mergingPrefersTheDevicesOwnPlainTextSysInfo() {
        let text = SysInfo(parsing: "ModelNumStr: M9282\n")
        let extended = SysInfo(parsing: "ModelNumStr: xMA448LL\npszSerialNumber: FILLED\n")

        let merged = text.merging(extended)
        #expect(merged.modelNumber == "M9282")
        #expect(merged.serialNumber == "FILLED")
    }

    @Test func volumeWithOnlyExtendedSysInfoStillIdentifies() throws {
        let root = try SyntheticDAP.make(
            writeSysInfo: false,
            sysInfoExtendedXML: Self.plist(modelNumber: "xMA002LL")
        )
        defer { SyntheticDAP.remove(root) }

        let volume = try DAPVolume.validate(at: root)
        #expect(volume.sysInfo.serialNumber == "5A6420ABVR0")
        #expect(volume.model.generation == "iPod 5G")
        #expect(volume.model.isUnknown == false)
        #expect(volume.model.requiresDatabaseSignature == .none)
    }

    @Test func volumeWithNeitherFileStillValidates() throws {
        let root = try SyntheticDAP.make(writeSysInfo: false)
        defer { SyntheticDAP.remove(root) }

        let volume = try DAPVolume.validate(at: root)
        #expect(volume.model == DeviceModel.unknown)
    }
}
