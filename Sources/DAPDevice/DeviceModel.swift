import Foundation

/// Which flavor of iTunesDB checksum/signature a device's firmware expects
/// on the database it reads back.
///
/// Apple introduced a checksum embedded in the iTunesDB (the `mhsd`
/// "hash58" field, computed from a per-device seed baked into firmware) on
/// the iPod classic (6th generation) and iPod nano (3rd generation), both
/// shipped September 2007. A later firmware revision switched to a
/// different algorithm colloquially called "hashAB". Devices older than
/// September 2007 (everything up through iPod mini, iPod photo, iPod video
/// 5th gen, nano 1st/2nd gen) do not check any signature at all, and
/// writing one is harmless-but-pointless for them.
///
/// This is modeled as an enum rather than a `Bool` so a later hash
/// algorithm can be added without changing every call site.
public enum DatabaseSignatureRequirement: Sendable, Equatable, CustomStringConvertible {
    /// No signature checked by firmware (all click-wheel iPods before the
    /// September 2007 refresh: mini, shuffle, photo/color, 4th gen, video).
    case none

    /// The "hash58" signature introduced with iPod classic 6th gen / nano
    /// 3rd gen (September 2007).
    case hash58

    /// The later "hashAB" signature variant used by some subsequent
    /// firmware revisions.
    case hashAB

    /// We could not identify the device. Refusing to write a database is
    /// the safe default here: a wrong guess about `.none` risks bricking a
    /// device that actually validates the signature, whereas a wrong guess
    /// about `.hash58`/`.hashAB` just means we decline to write until the
    /// model table is extended. Model this as "assume the strictest,
    /// least-forgiving case."
    case unknownAssumeRequired

    /// Short name for logs and the `dapctl` info dump.
    public var description: String {
        switch self {
        case .none: return "none"
        case .hash58: return "hash58"
        case .hashAB: return "hashAB"
        case .unknownAssumeRequired: return "unknown (assumed required)"
        }
    }

    /// The first half of a user-facing refusal: why we won't write.
    ///
    /// Written as a whole sentence per case rather than interpolating the
    /// enum into a template, because the two situations are genuinely
    /// different — "your device checks a signature we can't compute" is a
    /// missing feature, while "we don't know what your device checks" is a
    /// missing table entry the user can help us fix — and interpolating
    /// leaked the raw case name (`unknownAssumeRequired`) into a dialog.
    public var refusalExplanation: String {
        switch self {
        case .none:
            // Not reachable from a refusal path; present for exhaustiveness.
            return "This device's firmware does not check a database signature."
        case .hash58:
            return "This device's firmware checks a hash58 database signature, which Tarantado cannot compute yet."
        case .hashAB:
            return "This device's firmware checks a hashAB database signature, which Tarantado cannot compute yet."
        case .unknownAssumeRequired:
            return "Tarantado could not identify this device, so it cannot tell whether the firmware checks a database signature."
        }
    }
}

/// Broad product line. Drives things like whether the click wheel /
/// screen conventions (folder counts, artwork) apply.
public enum DeviceFamily: Sendable, Equatable {
    case classicOrTouch
    case mini
    case nano
    case shuffle
    case unknown
}

/// A resolved, human-meaningful description of a device model, derived from
/// its `SysInfo`. Carries the capability flags the rest of the app makes
/// sync decisions on.
public struct DeviceModel: Sendable, Equatable {
    public let displayName: String
    public let generation: String
    public let family: DeviceFamily
    public let requiresDatabaseSignature: DatabaseSignatureRequirement
    public let supportsArtwork: Bool
    public let musicFolderCount: Int

    /// Which `mhsd` section type this firmware builds its Playlists menu
    /// from, or `nil` when we have not verified it for this model.
    ///
    /// A real database carries playlists in more than one `mhsd` section —
    /// the master playlist is mirrored across two of them under a single
    /// persistent ID, and iTunes' own smart playlists sit in a third — and
    /// nothing in the bytes says which one the firmware reads. It cannot be
    /// inferred: on the verified mini 2G the browsable section is **not**
    /// the one holding the most playlists, so the obvious heuristic picks
    /// wrong. The only way to know is to write a playlist into a candidate
    /// section and look at the device, so this is a hardware-verified fact
    /// per model, like `requiresDatabaseSignature`.
    ///
    /// `nil` means "don't guess" — playlist creation refuses rather than
    /// filing a playlist somewhere the firmware may never show it.
    public let playlistSectionType: UInt32?

    /// True when this model could not be identified from `SysInfo` at all
    /// (as opposed to being identified as a known-unsupported model).
    public let isUnknown: Bool

    public init(
        displayName: String,
        generation: String,
        family: DeviceFamily,
        requiresDatabaseSignature: DatabaseSignatureRequirement,
        supportsArtwork: Bool,
        musicFolderCount: Int,
        playlistSectionType: UInt32? = nil,
        isUnknown: Bool = false
    ) {
        self.displayName = displayName
        self.generation = generation
        self.family = family
        self.requiresDatabaseSignature = requiresDatabaseSignature
        self.supportsArtwork = supportsArtwork
        self.musicFolderCount = musicFolderCount
        self.playlistSectionType = playlistSectionType
        self.isUnknown = isUnknown
    }

    /// Clearly-marked fallback for a device we couldn't identify. Assumes
    /// the strictest capability requirements throughout, so the app refuses
    /// to write rather than risk corrupting an unrecognized device.
    public static let unknown = DeviceModel(
        displayName: "Unknown iPod",
        generation: "unknown",
        family: .unknown,
        requiresDatabaseSignature: .unknownAssumeRequired,
        supportsArtwork: false,
        musicFolderCount: 50,
        isUnknown: true
    )

    // MARK: Lookup table

    /// Keyed by `ModelNumStr` (e.g. `"M9800"`), the primary identifier
    /// present in every SysInfo file. Entries here are limited to models we
    /// could positively verify — either against real hardware, or against
    /// independently corroborated product documentation. See
    /// `resolve(from:)` for the provenance of each entry.
    private static let byModelNumber: [String: DeviceModel] = [
        // Verified against a physically connected reference device
        // (`Tests/DAPDeviceTests/SysInfo-mini2g.txt`, ModelNumStr == "M9800").
        "M9800": DeviceModel(
            displayName: "iPod mini (2nd generation)",
            generation: "mini 2G",
            family: .mini,
            requiresDatabaseSignature: .none,
            supportsArtwork: false,
            musicFolderCount: 50,
            // Verified on the reference device 2026-08-18: playlists written
            // into mhsd section 3 appear in Music -> Playlists; identical
            // playlists written into sections 2 and 5 at the same time did
            // not appear at all.
            playlistSectionType: 3
        ),

        // Not independently hardware-verified; the 4GB/6GB mini 2G pairing
        // (M9800/M9802) is well documented and internally consistent with
        // the verified M9800 entry above (same generation, same launch).
        "M9802": DeviceModel(
            displayName: "iPod mini (2nd generation, 6GB)",
            generation: "mini 2G",
            family: .mini,
            requiresDatabaseSignature: .none,
            supportsArtwork: false,
            musicFolderCount: 50,
            // Same generation and firmware as the verified M9800, so it
            // carries that device's verified playlist section on the same
            // reasoning as the capabilities above. The other models in this
            // table leave it nil: no generation outside mini 2G has been
            // checked, and guessing risks filing playlists where the
            // firmware never shows them.
            playlistSectionType: 3
        ),

        // Not hardware-verified. iPod mini (1st generation), 2004.
        "M9160": DeviceModel(
            displayName: "iPod mini (1st generation)",
            generation: "mini 1G",
            family: .mini,
            requiresDatabaseSignature: .none,
            supportsArtwork: false,
            musicFolderCount: 50
        ),

        // Verified against a physically connected reference device
        // (`Tests/DAPDeviceTests/SysInfo-ipod4g.txt`, ModelNumStr == "M9282",
        // BoardHwName "iPod Q21", iPodFamily 4, firmware 3.1.1). Read back
        // 1516 tracks and 18 playlists across mhsd sections 3/2/5 — the same
        // section layout the verified mini 2G uses. Monochrome 2" screen, so
        // no artwork; 50 music folders confirmed on the device (F00-F49).
        // Predates the September 2007 hash58 refresh by three years, so no
        // database signature.
        "M9282": DeviceModel(
            displayName: "iPod (4th generation, 20GB)",
            generation: "iPod 4G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .none,
            supportsArtwork: false,
            musicFolderCount: 50,
            // Verified on the reference device 2026-08-24, same method as
            // the mini 2G: three identical playlists written into mhsd
            // sections 2, 3 and 5 in one pass, then booted into the Apple
            // firmware. Only the section 3 playlist appeared under Music ->
            // Playlists. Note this run also proved the *writer* had to be
            // fixed first — section-targeted insertion was landing playlists
            // in the wrong mhsd whenever two sections held byte-identical
            // playlist lists, which this device's database does.
            playlistSectionType: 3
        ),

        // Not hardware-verified. The 20GB/40GB 4G pairing (M9282/M9268,
        // A1059, July 2004) is corroborated by EveryMac and Low End Mac, and
        // is internally consistent with the verified M9282 above: same
        // generation, same enclosure, same firmware line, differing only in
        // disk size.
        "M9268": DeviceModel(
            displayName: "iPod (4th generation, 40GB)",
            generation: "iPod 4G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .none,
            supportsArtwork: false,
            musicFolderCount: 50,
            // Inherits the verified M9282's browsable section on the same
            // reasoning the mini 2G's 6GB sibling does: same generation,
            // same firmware line, differing only in disk size. The 5G
            // entries below stay nil — no device of that generation has
            // been checked, and guessing files playlists where the firmware
            // may never show them.
            playlistSectionType: 3
        ),

        // iPod 5th generation ("iPod with video", A1136, October 2005).
        // The four launch SKUs differ only in capacity and case color, and
        // are corroborated by EveryMac and iLounge model listings. No
        // signature, and the 2.5" color screen carries album art.
        //
        // The *generation* is hardware-verified (see the `iPodFamily` 6 case
        // in `resolve(iPodFamily:)`), but these SKU keys are not what a real
        // 5G matches on — the reference device reports no `ModelNumStr` at
        // all. They are kept for a device that does report one, and their
        // capabilities are held identical to the family-6 entry by
        // `fivethGenSKUTableAgreesWithTheFamilyFallback`, so a device's
        // fate never turns on whether iTunes happened to write a SKU.
        "MA002": DeviceModel(
            displayName: "iPod (5th generation, 30GB, white)",
            generation: "iPod 5G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .none,
            supportsArtwork: true,
            musicFolderCount: 50,
            playlistSectionType: 3
        ),
        "MA146": DeviceModel(
            displayName: "iPod (5th generation, 30GB, black)",
            generation: "iPod 5G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .none,
            supportsArtwork: true,
            musicFolderCount: 50,
            playlistSectionType: 3
        ),
        "MA003": DeviceModel(
            displayName: "iPod (5th generation, 60GB, white)",
            generation: "iPod 5G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .none,
            supportsArtwork: true,
            musicFolderCount: 50,
            playlistSectionType: 3
        ),
        "MA147": DeviceModel(
            displayName: "iPod (5th generation, 60GB, black)",
            generation: "iPod 5G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .none,
            supportsArtwork: true,
            musicFolderCount: 50,
            playlistSectionType: 3
        ),

        // iPod 5th generation "enhanced" (5.5G, September 2006) — same A1136
        // enclosure, brighter screen, 30GB/80GB. Model numbers per EveryMac's
        // 5th-generation-enhanced specs page. Still a year before hash58.
        // Same SKU-key caveat as the launch SKUs above; the reference device
        // could itself be one of these, since nothing it reports separates
        // 5G from 5.5G.
        // Worth listing separately from the 5G launch SKUs because flash-mod
        // rebuilds in the wild are usually 5.5G boards, and a reporter's
        // "iPod video" is as likely to be one of these as an MA002.
        "MA444": DeviceModel(
            displayName: "iPod (5th generation, 30GB, white)",
            generation: "iPod 5.5G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .none,
            supportsArtwork: true,
            musicFolderCount: 50,
            playlistSectionType: 3
        ),
        "MA446": DeviceModel(
            displayName: "iPod (5th generation, 30GB, black)",
            generation: "iPod 5.5G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .none,
            supportsArtwork: true,
            musicFolderCount: 50,
            playlistSectionType: 3
        ),
        "MA448": DeviceModel(
            displayName: "iPod (5th generation, 80GB, white)",
            generation: "iPod 5.5G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .none,
            supportsArtwork: true,
            musicFolderCount: 50,
            playlistSectionType: 3
        ),
        "MA450": DeviceModel(
            displayName: "iPod (5th generation, 80GB, black)",
            generation: "iPod 5.5G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .none,
            supportsArtwork: true,
            musicFolderCount: 50,
            playlistSectionType: 3
        ),

        // Confirmed to exist via product documentation search (SellYourMac /
        // EveryMac listings for MB147LL/A, September 2007, 80GB). The
        // hash58 requirement for this generation is not hardware-verified
        // here — it is the well-documented boundary used by the libgpod /
        // gtkpod open-source iPod projects, not something we observed on a
        // real 6th-gen classic.
        "MB147": DeviceModel(
            displayName: "iPod classic (6th generation, 80GB)",
            generation: "classic 6G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .hash58,
            supportsArtwork: true,
            musicFolderCount: 50
        ),

        // Confirmed to exist via product documentation search (120GB
        // variant, late 2008). Same signature caveat as MB147 above.
        "MB562": DeviceModel(
            displayName: "iPod classic (2nd generation / late 2008, 120GB)",
            generation: "classic 7G",
            family: .classicOrTouch,
            requiresDatabaseSignature: .hash58,
            supportsArtwork: true,
            musicFolderCount: 50
        ),

        // Confirmed to exist via product documentation search (8GB, light
        // blue, September 2007 — the nano generation that introduced
        // hash58 alongside the classic 6G). Signature requirement is the
        // same documented-but-not-hardware-verified caveat as above.
        "MB249": DeviceModel(
            displayName: "iPod nano (3rd generation, 8GB)",
            generation: "nano 3G",
            family: .nano,
            requiresDatabaseSignature: .hash58,
            supportsArtwork: true,
            musicFolderCount: 50
        ),
    ]

    // MARK: Resolution

    /// Resolves a `DeviceModel` from parsed `SysInfo`. Looks up
    /// `ModelNumStr` in the verified table first; if that's missing or
    /// unrecognized, falls back to a coarse `iPodFamily` heuristic; if
    /// that also fails, returns `.unknown`.
    public static func resolve(from sysInfo: SysInfo) -> DeviceModel {
        if let modelNumber = sysInfo.modelNumber, let known = byModelNumber[modelNumber] {
            return known
        }
        // Second chance for a model number that arrived via SysInfoExtended,
        // where the same field carries an `x` prefix and sometimes a region
        // suffix (`xMA002LL`) around the order number this table is keyed on.
        if let normalized = sysInfo.normalizedModelNumber, let known = byModelNumber[normalized] {
            return known
        }
        if let family = sysInfo.iPodFamily {
            return resolve(iPodFamily: family)
        }
        return .unknown
    }

    /// Coarse fallback keyed on the `iPodFamily` integer from SysInfo, used
    /// only when the specific `ModelNumStr` isn't in our verified table.
    /// `iPodFamily == 3` is what our verified mini 2G reports and `== 4`
    /// what our verified iPod 4G reports; we treat unrecognized family IDs
    /// as `.unknown` rather than guessing.
    private static func resolve(iPodFamily: UInt32) -> DeviceModel {
        switch iPodFamily {
        case 3:
            // Observed on the verified mini 2G (M9800). Family 3 covers
            // multiple click-wheel generations, though, so treat this
            // fallback path itself as low-confidence: identify as a mini
            // only in name, but keep the conservative "assume signature
            // required" posture since we don't actually know which
            // specific model this is.
            return DeviceModel(
                displayName: "iPod (family 3, unrecognized model)",
                generation: "unknown",
                family: .mini,
                requiresDatabaseSignature: .unknownAssumeRequired,
                supportsArtwork: false,
                musicFolderCount: 50,
                isUnknown: true
            )
        case 4:
            // Observed on the verified iPod 4G (M9282). As with family 3,
            // one family ID spans more than one model, so an unrecognized
            // ModelNumStr in this family keeps the conservative posture.
            return DeviceModel(
                displayName: "iPod (family 4, unrecognized model)",
                generation: "unknown",
                family: .classicOrTouch,
                requiresDatabaseSignature: .unknownAssumeRequired,
                supportsArtwork: false,
                musicFolderCount: 50,
                isUnknown: true
            )
        case 6:
            // Observed on a physically connected iPod 5th generation
            // ("video") — `Tests/DAPDeviceTests/SysInfoExtended-ipod5g.xml`,
            // FamilyID 6, UpdaterFamilyID 25, firmware 1.3.
            //
            // Unlike families 3 and 4, this case resolves to a *usable*
            // model rather than the conservative unknown fallback, because
            // on this generation the family ID is all we get. A 5G restored
            // by a later iTunes writes no plain-text `SysInfo` and a
            // `SysInfoExtended` with **no `ModelNumStr` and no
            // `BoardHwName`** — the reference device carries only
            // SerialNumber, FamilyID, UpdaterFamilyID and the build IDs. So
            // the eight MA002…MA450 entries above can never match a real
            // device of this generation, and holding the conservative
            // posture here would mean every 5G in the wild is permanently
            // unwritable, not merely unidentified.
            //
            // `.none` is hardware-verified on the reference device
            // 2026-08-26, not inferred from the pre-September-2007 hash58
            // boundary the SKU entries above rest on: a Tarantado-written
            // database was booted in the Apple firmware and the device read
            // it back intact — all 4342 tracks, no signature computed.
            //
            // The capacity/color SKU stays unresolved on purpose. Nothing
            // here depends on it, and the device supplies nothing to resolve
            // it with.
            return DeviceModel(
                displayName: "iPod (5th generation, \"video\")",
                generation: "iPod 5G",
                family: .classicOrTouch,
                requiresDatabaseSignature: .none,
                // Hardware-verified 2026-08-27, not just inherited from the
                // SKU table above: a track with embedded cover art was added
                // via `SyncEngine` (new `mhii`/`mhni` entries appended to the
                // device's real, pre-existing `ArtworkDB`, two thumbnails
                // appended to its real, pre-existing `.ithmb` files) and the
                // reference device displayed the art on its Now Playing
                // screen and played the track normally. This is also what
                // proved format IDs 1028 (100x100) and 1029 (200x200), both
                // RGB565LE — sourced from libgpod's `itdb_device.c` and
                // independently corroborated by iOpenPod, but now confirmed
                // against this exact device rather than either source alone.
                // See `DAPDB`'s `MHII`/`MHNI`/`ArtworkMHOD` and `DAPSync`'s
                // `ArtworkEncoder`.
                supportsArtwork: true,
                musicFolderCount: 50,
                // Verified on the reference device 2026-08-26, same method
                // as the mini 2G and the 4G: three playlists holding
                // identical tracks written into mhsd sections 2, 3 and 5 in
                // one pass, then booted into the Apple firmware. Only the
                // section 3 playlist appeared under Music -> Playlists.
                // Third generation in a row to browse section 3, and again
                // not the section holding the most playlists.
                playlistSectionType: 3
            )
        default:
            return .unknown
        }
    }
}
