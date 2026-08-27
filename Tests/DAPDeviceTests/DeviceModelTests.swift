import Foundation
import Testing
@testable import DAPDevice

@Suite struct DeviceModelTests {
    @Test func resolvesMini2GFromSampleSysInfo() throws {
        let sysInfo = try SysInfo(contentsOf: SyntheticDAP.sampleSysInfoURL)
        let model = DeviceModel.resolve(from: sysInfo)

        #expect(model.displayName == "iPod mini (2nd generation)")
        #expect(model.family == .mini)
        #expect(model.requiresDatabaseSignature == .none)
        #expect(model.supportsArtwork == false)
        #expect(model.musicFolderCount == 50)
        #expect(model.isUnknown == false)
    }

    @Test func resolvesMini1GAndMini2G6GBByModelNumber() {
        let mini1G = SysInfo(parsing: "ModelNumStr: M9160\n")
        let resolved1G = DeviceModel.resolve(from: mini1G)
        #expect(resolved1G.family == .mini)
        #expect(resolved1G.requiresDatabaseSignature == .none)
        #expect(resolved1G.isUnknown == false)

        let mini2G6GB = SysInfo(parsing: "ModelNumStr: M9802\n")
        let resolved2G6GB = DeviceModel.resolve(from: mini2G6GB)
        #expect(resolved2G6GB.family == .mini)
        #expect(resolved2G6GB.requiresDatabaseSignature == .none)
    }

    @Test func resolvesPostHash58ModelsAsRequiringSignature() {
        let classic6G = SysInfo(parsing: "ModelNumStr: MB147\n")
        let resolvedClassic = DeviceModel.resolve(from: classic6G)
        #expect(resolvedClassic.family == .classicOrTouch)
        #expect(resolvedClassic.requiresDatabaseSignature == .hash58)
        #expect(resolvedClassic.supportsArtwork == true)

        let nano3G = SysInfo(parsing: "ModelNumStr: MB249\n")
        let resolvedNano = DeviceModel.resolve(from: nano3G)
        #expect(resolvedNano.family == .nano)
        #expect(resolvedNano.requiresDatabaseSignature == .hash58)
    }

    @Test func resolvesIPod5GFromRealSysInfoExtended() throws {
        let sysInfo = try #require(
            SysInfo(sysInfoExtendedContentsOf: SyntheticDAP.sampleSysInfoExtended5GURL)
        )

        // The premise of the family-6 fallback: this generation hands us no
        // SKU at all, so the MA002…MA450 table entries can never match it.
        #expect(sysInfo.modelNumber == nil)
        #expect(sysInfo.boardHwName == nil)
        #expect(sysInfo.iPodFamily == 6)

        let model = DeviceModel.resolve(from: sysInfo)
        #expect(model.generation == "iPod 5G")
        #expect(model.family == .classicOrTouch)
        #expect(model.supportsArtwork == true)
        #expect(model.musicFolderCount == 50)

        // Writable: the whole point of the entry.
        #expect(model.isUnknown == false)
        #expect(model.requiresDatabaseSignature == .none)

        // Browsable mhsd section, verified on this exact device 2026-08-26.
        #expect(model.playlistSectionType == 3)
    }

    @Test func fivethGenSKUTableAgreesWithTheFamilyFallback() {
        // If someone later edits one of the SKU entries, the family-6
        // fallback a real device actually lands on must not drift away from
        // it — a device would then be sync-capable or not depending purely
        // on whether iTunes happened to write a ModelNumStr.
        let fallback = DeviceModel.resolve(from: SysInfo(parsing: "iPodFamily: 0x00000006\n"))
        for sku in ["MA002", "MA146", "MA003", "MA147", "MA444", "MA446", "MA448", "MA450"] {
            let resolved = DeviceModel.resolve(from: SysInfo(parsing: "ModelNumStr: \(sku)\n"))
            #expect(resolved.requiresDatabaseSignature == fallback.requiresDatabaseSignature, "\(sku)")
            #expect(resolved.supportsArtwork == fallback.supportsArtwork, "\(sku)")
            #expect(resolved.musicFolderCount == fallback.musicFolderCount, "\(sku)")
            #expect(resolved.family == fallback.family, "\(sku)")
            #expect(resolved.playlistSectionType == fallback.playlistSectionType, "\(sku)")
        }
    }

    @Test func unknownModelNumberWithNoFamilyFallsBackToUnknown() {
        let sysInfo = SysInfo(parsing: "ModelNumStr: ZZ9999\n")
        let model = DeviceModel.resolve(from: sysInfo)
        #expect(model.isUnknown == true)
        #expect(model.requiresDatabaseSignature == .unknownAssumeRequired)
        #expect(model == DeviceModel.unknown)
    }

    @Test func completelyEmptySysInfoResolvesToUnknown() {
        let model = DeviceModel.resolve(from: SysInfo(raw: [:]))
        #expect(model.isUnknown == true)
        #expect(model.requiresDatabaseSignature == .unknownAssumeRequired)
    }

    @Test func unknownModelNumberButKnownFamilyFallsBackConservatively() {
        // Same iPodFamily as the verified mini 2G, but a ModelNumStr we
        // don't have in the table: should NOT silently claim "no signature
        // required" just because family 3 usually means that.
        let sysInfo = SysInfo(parsing: "ModelNumStr: M0000\niPodFamily: 0x00000003\n")
        let model = DeviceModel.resolve(from: sysInfo)
        #expect(model.requiresDatabaseSignature == .unknownAssumeRequired)
        #expect(model.isUnknown == true)
    }
}

/// Coverage for the two generations added alongside the reference iPod 4G:
/// the click-wheel 4G itself (hardware-verified) and the 5th-generation
/// "iPod with video" family (documented model numbers).
@Suite struct FourthAndFifthGenerationTests {
    @Test func resolvesIPod4GFromRealDeviceSysInfo() throws {
        let sysInfo = try SysInfo(contentsOf: SyntheticDAP.sampleSysInfo4GURL)

        // Sanity-check the fixture is the device we actually read.
        #expect(sysInfo.modelNumber == "M9282")
        #expect(sysInfo.boardHwName == "iPod Q21")
        #expect(sysInfo.iPodFamily == 4)
        #expect(sysInfo.serialNumber == "EXAMPLE0002")

        let model = DeviceModel.resolve(from: sysInfo)
        #expect(model.displayName == "iPod (4th generation, 20GB)")
        #expect(model.generation == "iPod 4G")
        #expect(model.family == .classicOrTouch)
        #expect(model.isUnknown == false)
        // The whole point: a 2004 device predates hash58, so it is writable.
        #expect(model.requiresDatabaseSignature == .none)
        #expect(model.supportsArtwork == false)
        #expect(model.musicFolderCount == 50)
        // Hardware-verified 2026-08-24: of identical playlists written into
        // mhsd sections 2, 3 and 5, only the section 3 one appeared under
        // Music -> Playlists on the device.
        #expect(model.playlistSectionType == 3)
    }

    @Test func resolvesIPod4G40GBSibling() {
        let model = DeviceModel.resolve(from: SysInfo(parsing: "ModelNumStr: M9268\n"))
        #expect(model.generation == "iPod 4G")
        #expect(model.requiresDatabaseSignature == .none)
        #expect(model.isUnknown == false)
        #expect(model.playlistSectionType == 3)
    }

    @Test func fifthGenerationBrowsesSectionThree() {
        // Was `fifthGenerationPlaylistSectionStaysUnverified`, asserting nil
        // while no 5G had been checked. Verified on hardware 2026-08-26:
        // playlists written into sections 2, 3 and 5 in one pass, and only
        // the section 3 one appeared under Music -> Playlists. The guard now
        // pins the answer instead of the absence of one.
        for number in ["MA002", "MA146", "MA003", "MA147", "MA444", "MA446", "MA448", "MA450"] {
            let model = DeviceModel.resolve(from: SysInfo(parsing: "ModelNumStr: \(number)\n"))
            #expect(model.playlistSectionType == 3, "\(number)")
        }
    }

    @Test func resolvesEveryFifthGenerationModelNumber() {
        let fifthGen = ["MA002", "MA146", "MA003", "MA147"]
        for number in fifthGen {
            let model = DeviceModel.resolve(from: SysInfo(parsing: "ModelNumStr: \(number)\n"))
            #expect(model.generation == "iPod 5G", "\(number)")
            #expect(model.family == .classicOrTouch, "\(number)")
            #expect(model.requiresDatabaseSignature == .none, "\(number)")
            #expect(model.supportsArtwork == true, "\(number)")
            #expect(model.isUnknown == false, "\(number)")
        }

        let enhanced = ["MA444", "MA446", "MA448", "MA450"]
        for number in enhanced {
            let model = DeviceModel.resolve(from: SysInfo(parsing: "ModelNumStr: \(number)\n"))
            #expect(model.generation == "iPod 5.5G", "\(number)")
            #expect(model.requiresDatabaseSignature == .none, "\(number)")
            #expect(model.supportsArtwork == true, "\(number)")
        }
    }

    @Test func fifthGenerationModelNumberFromSysInfoExtendedIsNormalized() {
        // SysInfoExtended writes the order number with an `x` prefix and a
        // region suffix; the lookup table is keyed on the bare number.
        let sysInfo = SysInfo(parsing: "ModelNumStr: xMA448LL\n")
        #expect(sysInfo.normalizedModelNumber == "MA448")

        let model = DeviceModel.resolve(from: sysInfo)
        #expect(model.generation == "iPod 5.5G")
        #expect(model.isUnknown == false)
    }

    @Test func unrecognizedModelInFamily4StaysConservative() {
        // A 4G-family device whose exact model we don't have must not
        // inherit the verified M9282's "no signature required".
        let sysInfo = SysInfo(parsing: "ModelNumStr: M0000\niPodFamily: 0x00000004\n")
        let model = DeviceModel.resolve(from: sysInfo)
        #expect(model.isUnknown == true)
        #expect(model.requiresDatabaseSignature == .unknownAssumeRequired)
    }

    @Test func refusalExplanationNeverLeaksTheRawCaseName() {
        // A dialog on a reporter's device read "requires a
        // unknownAssumeRequired database signature".
        for requirement in [DatabaseSignatureRequirement.hash58, .hashAB, .unknownAssumeRequired] {
            #expect(!requirement.refusalExplanation.contains("unknownAssumeRequired"))
            #expect(requirement.refusalExplanation.hasSuffix("."))
        }
        #expect(DatabaseSignatureRequirement.hash58.refusalExplanation.contains("hash58"))
        #expect(DatabaseSignatureRequirement.unknownAssumeRequired.description == "unknown (assumed required)")
    }
}
