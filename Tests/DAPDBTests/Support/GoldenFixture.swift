import Foundation
import Testing

/// Locates and loads `golden-mini2g.itunesdb`, a byte-for-byte copy of the
/// iTunesDB from a physical iPod mini 2nd gen (model M9800, firmware 1.4.1).
///
/// Left byte-for-byte deliberately: its value is that it is exactly what a
/// real device wrote, so the parser is tested against reality rather than
/// against our idea of it. It carries no device serial or GUID — only the
/// owner's account name in the master playlist title.
enum GoldenFixture {
    static func url() throws -> URL {
        // Package.swift copies the whole "Resources" directory into the test
        // bundle (`.copy("Resources")`), so try the nested path first, then
        // fall back to a flattened layout in case SwiftPM's resource bundler
        // changes how it lays things out on some platform/toolchain.
        if let url = Bundle.module.url(forResource: "Resources/golden-mini2g", withExtension: "itunesdb") {
            return url
        }
        if let url = Bundle.module.url(forResource: "golden-mini2g", withExtension: "itunesdb") {
            return url
        }
        if let url = Bundle.module.url(forResource: "golden-mini2g", withExtension: "itunesdb", subdirectory: "Resources") {
            return url
        }
        Issue.record("Could not locate golden-mini2g.itunesdb in Bundle.module")
        throw CocoaError(.fileNoSuchFile)
    }

    static func data() throws -> Data {
        try Data(contentsOf: try url())
    }
}
