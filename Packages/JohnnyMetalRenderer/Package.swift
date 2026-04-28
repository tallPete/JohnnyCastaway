// swift-tools-version: 6.0
//
// JohnnyMetalRenderer — uploads JohnnyEngine's 640×480 indexed
// framebuffer to a Metal texture and renders to a CAMetalLayer with
// nearest-neighbour integer scaling. Optional CRT-style post-process
// shader as a configurable preference (post-MVP).

import PackageDescription

let package = Package(
    name: "JohnnyMetalRenderer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JohnnyMetalRenderer", targets: ["JohnnyMetalRenderer"]),
    ],
    dependencies: [
        .package(path: "../JohnnyEngine"),
    ],
    targets: [
        .target(
            name: "JohnnyMetalRenderer",
            dependencies: ["JohnnyEngine"],
            linkerSettings: [
                // Explicit linking ensures both Xcode and swift-test builds
                // find these frameworks without relying on auto-link.
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(
            name: "JohnnyMetalRendererTests",
            dependencies: ["JohnnyMetalRenderer"],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
