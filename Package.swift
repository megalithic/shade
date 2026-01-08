// swift-tools-version:5.9
import PackageDescription
import Foundation

// GhosttyKit path resolution:
// 1. GHOSTTYKIT_PATH environment variable (set by Nix flake or manually)
// 2. Standard locations checked in order:
//    - ./vendor/GhosttyKit (vendored in repo)
//    - ~/src/ghostty/macos/GhosttyKit.xcframework/macos-arm64
//    - ~/src/ghostty-research/macos/GhosttyKit.xcframework/macos-arm64
//    - ../ghostty/macos/GhosttyKit.xcframework/macos-arm64 (sibling dir)

struct GhosttyKitPaths {
    let headers: String
    let modulemap: String
    let library: String
}

func findGhosttyKit() -> GhosttyKitPaths {
    // Check environment variable first (set by Nix flake)
    if let envPath = ProcessInfo.processInfo.environment["GHOSTTYKIT_PATH"] {
        // Nix build output structure: lib/libghostty-fat.a, include/ghostty.h
        let nixLib = "\(envPath)/lib/libghostty-fat.a"
        let nixHeaders = "\(envPath)/include"

        if FileManager.default.fileExists(atPath: nixLib) {
            return GhosttyKitPaths(
                headers: nixHeaders,
                modulemap: "\(nixHeaders)/module.modulemap",
                library: nixLib
            )
        }

        // XCFramework structure: Headers/, libghostty-fat.a
        let xcfwLib = "\(envPath)/libghostty-fat.a"
        let xcfwHeaders = "\(envPath)/Headers"

        if FileManager.default.fileExists(atPath: xcfwLib) {
            return GhosttyKitPaths(
                headers: xcfwHeaders,
                modulemap: "\(xcfwHeaders)/module.modulemap",
                library: xcfwLib
            )
        }
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path

    // Standard xcframework locations to check
    let candidates = [
        "./vendor/GhosttyKit",
        "\(home)/src/ghostty/macos/GhosttyKit.xcframework/macos-arm64",
        "\(home)/src/ghostty-research/macos/GhosttyKit.xcframework/macos-arm64",
        "../ghostty/macos/GhosttyKit.xcframework/macos-arm64",
    ]

    for candidate in candidates {
        let libPath = "\(candidate)/libghostty-fat.a"
        if FileManager.default.fileExists(atPath: libPath) {
            return GhosttyKitPaths(
                headers: "\(candidate)/Headers",
                modulemap: "\(candidate)/Headers/module.modulemap",
                library: libPath
            )
        }
    }

    // Fallback - will fail at build time with clear error
    return GhosttyKitPaths(
        headers: "./vendor/GhosttyKit/Headers",
        modulemap: "./vendor/GhosttyKit/Headers/module.modulemap",
        library: "./vendor/GhosttyKit/libghostty-fat.a"
    )
}

let ghostty = findGhosttyKit()

let package = Package(
    name: "shade",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "shade", targets: ["shade"]),
        .library(name: "MsgpackRpc", targets: ["MsgpackRpc"]),
        .library(name: "ContextGatherer", targets: ["ContextGatherer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/a2/MessagePack.swift.git", from: "4.0.0"),
    ],
    targets: [
        // Pure msgpack-rpc protocol library (no GhosttyKit dependency)
        .target(
            name: "MsgpackRpc",
            dependencies: [
                .product(name: "MessagePack", package: "MessagePack.swift"),
            ],
            path: "Sources/MsgpackRpc"
        ),
        // Context gathering library (no GhosttyKit dependency)
        .target(
            name: "ContextGatherer",
            dependencies: [],
            path: "Sources/ContextGatherer"
        ),
        // Main executable with GhosttyKit
        .executableTarget(
            name: "shade",
            dependencies: [
                "MsgpackRpc",
                "ContextGatherer",
                .product(name: "MessagePack", package: "MessagePack.swift"),
            ],
            path: "Sources",
            exclude: ["MsgpackRpc", "ContextGatherer"],
            swiftSettings: [
                // Import path for GhosttyKit module
                .unsafeFlags([
                    "-I", ghostty.headers,
                    "-Xcc", "-fmodule-map-file=\(ghostty.modulemap)",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    // Link the static library
                    ghostty.library,
                ]),
                // System frameworks required by libghostty
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon"),
                .linkedFramework("Foundation"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
                // Link C++ standard library (required by Zig builds)
                .linkedLibrary("c++"),
            ]
        ),
        // Tests for MsgpackRpc protocol
        .testTarget(
            name: "MsgpackRpcTests",
            dependencies: [
                "MsgpackRpc",
                .product(name: "MessagePack", package: "MessagePack.swift"),
            ],
            path: "Tests/MsgpackRpcTests"
        ),
        // Tests for ContextGatherer
        .testTarget(
            name: "ContextGathererTests",
            dependencies: [
                "ContextGatherer",
            ],
            path: "Tests/ContextGathererTests"
        ),
        // Tests for ShadeServer (uses MsgpackRpc for protocol tests)
        // Note: Full integration tests require running Shade
        .testTarget(
            name: "ShadeServerTests",
            dependencies: [
                "MsgpackRpc",
                .product(name: "MessagePack", package: "MessagePack.swift"),
            ],
            path: "Tests/ShadeServerTests"
        ),
    ]
)
