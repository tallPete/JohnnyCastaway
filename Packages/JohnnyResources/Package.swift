// swift-tools-version: 6.0
//
// JohnnyResources — parser for Sierra/Dynamix RESOURCE.MAP and RESOURCE.001
// container files used by the 1992 "Johnny Castaway" screensaver.
//
// Pure functions, no UI dependencies. Translates from jc_reborn's resource.c
// and uncompress.c. See ../../README.md for the project overview.

import PackageDescription

let package = Package(
    name: "JohnnyResources",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JohnnyResources", targets: ["JohnnyResources"]),
    ],
    targets: [
        .target(name: "JohnnyResources"),
        .testTarget(
            name: "JohnnyResourcesTests",
            dependencies: ["JohnnyResources"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
