import Foundation

/// Parsed contents of `iPod_Control/Device/SysInfo`.
///
/// The file is a simple `key: value` text format, one entry per line. Some
/// values carry a parenthesized human-readable form after the raw value,
/// e.g. `visibleBuildID: 0x01418000 (1.4.1)`. `SysInfo` keeps the full raw
/// table (trimmed, but otherwise verbatim) alongside a handful of typed
/// accessors for the fields the rest of the app cares about.
public struct SysInfo: Sendable, Equatable {
    /// Raw `key -> value` pairs exactly as found in the file (values are
    /// trimmed of surrounding whitespace but not otherwise interpreted).
    public let raw: [String: String]

    public init(raw: [String: String]) {
        self.raw = raw
    }

    /// Parses the `key: value` text format used by `iPod_Control/Device/SysInfo`.
    ///
    /// Tolerant of: CRLF or LF line endings, blank lines (including a
    /// trailing blank line), extra whitespace around the key/value, and
    /// unrecognized keys (kept in `raw` for callers that need them).
    /// Lines with no `:` separator, or an empty key, are skipped.
    public init(parsing text: String) {
        var pairs: [String: String] = [:]
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }
            guard let colonIndex = trimmedLine.firstIndex(of: ":") else { continue }
            let key = trimmedLine[trimmedLine.startIndex..<colonIndex]
                .trimmingCharacters(in: .whitespaces)
            let value = trimmedLine[trimmedLine.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            pairs[key] = value
        }
        self.raw = pairs
    }

    /// Loads and parses a SysInfo file from disk.
    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        // SysInfo is plain ASCII/UTF-8 text on every known device.
        let text = String(decoding: data, as: UTF8.self)
        self.init(parsing: text)
    }

    // MARK: SysInfoExtended

    /// Parses `iPod_Control/Device/SysInfoExtended` — the XML property list
    /// Apple's later iTunes versions write *instead of* the plain-text
    /// `SysInfo` file — into the same key space as `init(parsing:)`.
    ///
    /// This is not a nicety: a device restored by a newer iTunes (or by one
    /// of the flash-mod rebuild tools people use on 5th-gen iPods) can have
    /// no `SysInfo` at all, and then every identifying field reads back
    /// empty and the model resolves to `.unknown` no matter how complete
    /// the lookup table is.
    ///
    /// The plist uses its own key names and types, so they are translated
    /// onto the `SysInfo` names the rest of the app already reads. Values
    /// that are integers in the plist are re-rendered in the `0x…` hex form
    /// the text file uses, so the typed accessors below need no special
    /// cases.
    public init?(sysInfoExtended data: Data) {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        var pairs: [String: String] = [:]

        func copyString(_ plistKey: String, to sysInfoKey: String) {
            if let value = dictionary[plistKey] as? String, !value.isEmpty {
                pairs[sysInfoKey] = value
            }
        }
        func copyHex(_ plistKey: String, to sysInfoKey: String, width: Int) {
            switch dictionary[plistKey] {
            case let number as NSNumber:
                pairs[sysInfoKey] = "0x" + String(format: "%0\(width)llX", number.uint64Value)
            case let text as String where !text.isEmpty:
                // Some writers emit the GUID as a bare hex string with no
                // `0x`; normalize so `parseHexPrefix` reads it as hex rather
                // than failing an all-digits decimal parse.
                pairs[sysInfoKey] = text.lowercased().hasPrefix("0x") ? text : "0x" + text
            default:
                break
            }
        }

        copyString("ModelNumStr", to: "ModelNumStr")
        copyString("SerialNumber", to: "pszSerialNumber")
        copyString("BoardHwName", to: "BoardHwName")
        copyHex("FirewireGuid", to: "FirewireGuid", width: 16)
        copyHex("FamilyID", to: "iPodFamily", width: 8)
        copyHex("UpdaterFamilyID", to: "updaterFamily", width: 8)
        copyHex("VisibleBuildID", to: "visibleBuildID", width: 8)
        copyHex("BuildID", to: "buildID", width: 8)

        guard !pairs.isEmpty else { return nil }
        self.raw = pairs
    }

    /// Loads `SysInfoExtended` from disk, returning nil if it is absent or
    /// isn't a readable plist.
    public init?(sysInfoExtendedContentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(sysInfoExtended: data)
    }

    /// Returns a copy of `self` with any field it is missing filled in from
    /// `other`. Used to let `SysInfoExtended` supply what a truncated or
    /// absent `SysInfo` didn't — `self` always wins on conflict, because
    /// the plain-text file is what the device itself wrote.
    public func merging(_ other: SysInfo) -> SysInfo {
        SysInfo(raw: raw.merging(other.raw) { mine, _ in mine })
    }

    // MARK: Typed accessors

    public var serialNumber: String? { raw["pszSerialNumber"] }
    public var modelNumber: String? { raw["ModelNumStr"] }
    public var boardHwName: String? { raw["BoardHwName"] }

    /// `ModelNumStr` reduced to the bare five-character Apple order number
    /// used as the key of `DeviceModel`'s lookup table.
    ///
    /// The plain-text `SysInfo` on a 4th-gen iPod reports exactly `M9282`,
    /// but the same field in `SysInfoExtended` is written with an `x`
    /// prefix and sometimes a region suffix (`xMA002LL`). Every Apple order
    /// number in the table is five characters, so strip the prefix and trim
    /// to that; callers try the verbatim value first, so this only ever
    /// acts as a second chance.
    public var normalizedModelNumber: String? {
        guard var value = modelNumber?.trimmingCharacters(in: .whitespaces).uppercased(),
              !value.isEmpty else { return nil }
        if value.hasPrefix("X") { value.removeFirst() }
        guard value.count >= 5 else { return nil }
        return String(value.prefix(5))
    }

    /// `FirewireGuid: 0x000A270000000001` as a `UInt64`.
    public var firewireGUID: UInt64? {
        Self.parseHexPrefix(raw["FirewireGuid"])
    }

    /// `iPodFamily: 0x00000003` as a `UInt32`.
    public var iPodFamily: UInt32? {
        guard let value = Self.parseHexPrefix(raw["iPodFamily"]) else { return nil }
        return UInt32(truncatingIfNeeded: value)
    }

    /// Raw hex portion of `visibleBuildID`, e.g. `0x01418000` from
    /// `visibleBuildID: 0x01418000 (1.4.1)`.
    public var visibleBuildIDHex: UInt32? {
        guard let rawValue = raw["visibleBuildID"] else { return nil }
        let hexToken = Self.firstToken(of: rawValue)
        guard let value = Self.parseHexPrefix(hexToken) else { return nil }
        return UInt32(truncatingIfNeeded: value)
    }

    /// Human-readable portion of `visibleBuildID`, e.g. `"1.4.1"` from
    /// `visibleBuildID: 0x01418000 (1.4.1)`.
    public var visibleBuildIDVersion: String? {
        Self.parenthesizedSuffix(of: raw["visibleBuildID"])
    }

    // MARK: Parsing helpers

    /// Returns the leading whitespace-delimited token of a value string,
    /// e.g. `"0x01418000"` from `"0x01418000 (1.4.1)"`.
    private static func firstToken(of value: String) -> String {
        String(value.split(separator: " ", maxSplits: 1).first ?? Substring(value))
    }

    /// Parses a leading `0x`-prefixed hex token (optionally followed by a
    /// parenthesized human-readable suffix) into an unsigned integer.
    private static func parseHexPrefix(_ value: String?) -> UInt64? {
        guard let value else { return nil }
        let token = firstToken(of: value)
        let lower = token.lowercased()
        guard lower.hasPrefix("0x") else {
            return UInt64(token)
        }
        return UInt64(lower.dropFirst(2), radix: 16)
    }

    /// Extracts the text inside a trailing `(...)` group, e.g. `"1.4.1"`
    /// from `"0x01418000 (1.4.1)"`.
    private static func parenthesizedSuffix(of value: String?) -> String? {
        guard let value else { return nil }
        guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close else {
            return nil
        }
        let inner = value[value.index(after: open)..<close]
        return inner.trimmingCharacters(in: .whitespaces)
    }
}
