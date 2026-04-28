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
            dependencies: ["JohnnyEngine"]
        ),
        .testTarget(
            name: "JohnnyMetalRendererTests",
            dependencies: ["JohnnyMetalRenderer"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
