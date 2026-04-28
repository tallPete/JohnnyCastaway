// swift-tools-version: 6.0
//
// JohnnyEngine — runtime for the Johnny Castaway screensaver: scene
// scheduler, walking algorithm, TTM/ADS interpreter, sprite compositor,
// holiday Easter-egg date logic. Outputs a 640×480 indexed-colour
// framebuffer per tick. No graphics-framework dependency; the renderer
// (JohnnyMetalRenderer) consumes the framebuffer separately.

import PackageDescription

let package = Package(
    name: "JohnnyEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JohnnyEngine", targets: ["JohnnyEngine"]),
    ],
    dependencies: [
        .package(path: "../JohnnyResources"),
    ],
    targets: [
        .target(
            name: "JohnnyEngine",
            dependencies: ["JohnnyResources"]
        ),
        .testTarget(
            name: "JohnnyEngineTests",
            dependencies: ["JohnnyEngine"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
