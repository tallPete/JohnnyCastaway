// swift-tools-version: 6.0
//
// JohnnyDebug — SwiftUI overlay (frame stepper, scene picker, current
// scene/tick readout, "force date" picker for holiday testing). Reused
// by the JohnnyDebugApp host and (gated by a settings flag) by the
// .saver itself for in-the-wild diagnosis.

import PackageDescription

let package = Package(
    name: "JohnnyDebug",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JohnnyDebug", targets: ["JohnnyDebug"]),
    ],
    dependencies: [
        .package(path: "../JohnnyEngine"),
        .package(path: "../JohnnyMetalRenderer"),
    ],
    targets: [
        .target(
            name: "JohnnyDebug",
            dependencies: ["JohnnyEngine", "JohnnyMetalRenderer"]
        ),
        .testTarget(
            name: "JohnnyDebugTests",
            dependencies: ["JohnnyDebug"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
