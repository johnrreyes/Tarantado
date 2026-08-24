import Foundation

/// Shared display formatting for byte counts and durations, used across
/// every screen so numbers read consistently.
enum Formatting {
    static func bytes(_ value: Int64) -> String {
        // A fresh formatter per call rather than a cached static one:
        // `ByteCountFormatter` isn't `Sendable`, and this is called from
        // both the main actor and background contexts.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, value))
    }

    /// `mm:ss` (or `h:mm:ss` past an hour), matching `MHIT.length`'s
    /// millisecond units.
    static func duration(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
