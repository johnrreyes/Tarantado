// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DAPKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DAPDB", targets: ["DAPDB"]),
        .library(name: "DAPDevice", targets: ["DAPDevice"]),
        .library(name: "DAPSync", targets: ["DAPSync"]),
        .library(name: "DAPUI", targets: ["DAPUI"]),
        .executable(name: "dapctl", targets: ["dapctl"]),
    ],
    targets: [
        // Pure Foundation. The iTunesDB binary format: parse, mutate, serialize.
        .target(name: "DAPDB", swiftSettings: [.swiftLanguageMode(.v6)]),

        // Pure Foundation. Volume validation, device identity, on-disk layout.
        .target(name: "DAPDevice", dependencies: ["DAPDB"], swiftSettings: [.swiftLanguageMode(.v6)]),

        // + AVFoundation. Source scanning, diffing, applying.
        .target(name: "DAPSync", dependencies: ["DAPDB", "DAPDevice"], swiftSettings: [.swiftLanguageMode(.v6)]),

        // + SwiftUI. Shared views for the iOS and macOS apps.
        .target(name: "DAPUI", dependencies: ["DAPSync"], swiftSettings: [.swiftLanguageMode(.v6)]),

        // Command-line harness for validating the engine against real hardware
        // before any UI exists. macOS only.
        // Builds a synthetic volume with invented demo content for App Store
        // screenshots. Deliberately not listed in `products`: it is a
        // development tool, not part of the shipping app.
        .executableTarget(name: "demoseed", dependencies: ["DAPDB"], swiftSettings: [.swiftLanguageMode(.v6)]),

        .executableTarget(name: "dapctl", dependencies: ["DAPSync"], swiftSettings: [.swiftLanguageMode(.v6)]),

        .testTarget(
            name: "DAPDBTests",
            dependencies: ["DAPDB"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DAPDeviceTests",
            dependencies: ["DAPDevice"],
            resources: [.process("SysInfo-mini2g.txt"), .process("SysInfo-ipod4g.txt")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "DAPSyncTests", dependencies: ["DAPSync"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "DAPUITests",
            dependencies: ["DAPUI"],
            // Same 8 KB device database DAPDBTests uses. Copied rather than
            // shared because SwiftPM resources must live inside the target
            // that declares them, and the UI's edit operations need a real
            // parseable database to act on.
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
