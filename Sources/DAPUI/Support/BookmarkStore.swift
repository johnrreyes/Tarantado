import Foundation

/// Best-effort persistence of the security-scoped bookmark for the last
/// connected DAP volume.
///
/// Per `DAPVolume`'s own documentation, a security-scoped bookmark for a
/// removable/USB volume (which is how a mounted DAP is exposed via the
/// document picker) does **not** reliably resolve after the volume is
/// remounted. So this store is purely a best-effort optimization: try the
/// saved bookmark once on launch, and silently fall back to showing
/// "Connect DAP" on any failure. Callers must never surface a bookmark
/// resolution failure to the user as an error.
enum BookmarkStore {
    private static let key = "com.johnreyes.Tarantado.lastVolumeBookmark"

    static func save(_ data: Data) {
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
