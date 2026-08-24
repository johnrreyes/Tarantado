import Foundation

/// iTunesDB timestamps are stored as seconds since the classic Mac ("HFS+")
/// epoch: 1904-01-01 00:00:00 UTC, not the Unix epoch. A raw value of 0 means
/// "unset"/never, and is treated as `nil` rather than as the epoch itself.
public enum MacEpoch {
    /// Seconds between 1904-01-01 00:00:00 UTC and 1970-01-01 00:00:00 UTC.
    public static let secondsToUnixEpoch: Int64 = 2_082_844_800

    /// Converts a raw Mac-epoch-seconds field to a `Date`, or `nil` if unset (0).
    public static func date(fromRaw raw: UInt32) -> Date? {
        guard raw != 0 else { return nil }
        let unixSeconds = Int64(raw) - secondsToUnixEpoch
        return Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    }

    /// Converts a `Date` to a raw Mac-epoch-seconds field. `nil` (or a date
    /// that doesn't fit in a `UInt32` count of seconds since 1904) becomes 0.
    public static func raw(from date: Date?) -> UInt32 {
        guard let date else { return 0 }
        let unixSeconds = Int64(date.timeIntervalSince1970.rounded())
        let macSeconds = unixSeconds + secondsToUnixEpoch
        guard macSeconds > 0, macSeconds <= Int64(UInt32.max) else { return 0 }
        return UInt32(macSeconds)
    }
}
