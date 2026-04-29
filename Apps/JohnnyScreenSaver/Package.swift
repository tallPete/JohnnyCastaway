// swift-tools-version: 6.0
//
// JohnnyScreenSaver — the .saver bundle target.
//
// SwiftPM can't natively produce a .saver bundle (a macOS plugin
// bundle with extension .saver, loaded via CFBundle by the
// legacyScreenSaver host process). We work around this by producing
// a *dynamic library* here, then wrapping it in the .saver bundle
// structure via Scripts/build-saver.sh.
//
// The dylib's Mach-O `MH_BUNDLE` type is achieved by passing the
// `-bundle` linker flag (see linkerSettings.unsafeFlags below) so the
// loader treats it correctly when CFBundle dlopen()s it.
//
// Building:
//   $ Scripts/build-saver.sh
//
// Installing:
//   $ Scripts/build-saver.sh --install
//   (copies to ~/Library/Screen Savers/)

import PackageDescription

let packageDir: String = {
    let fp     = String(describing: #filePath)
    let suffix = "/Package.swift"
    return fp.hasSuffix(suffix) ? String(fp.dropLast(suffix.count)) : fp
}()

let package = Package(
    name: "JohnnyScreenSaver",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "JohnnyScreenSaver",
            type: .dynamic,
            targets: ["JohnnyScreenSaver"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/JohnnyResources"),
        .package(path: "../../Packages/JohnnyEngine"),
        .package(path: "../../Packages/JohnnyMetalRenderer"),
        .package(path: "../../Packages/JohnnyDebug"),
    ],
    targets: [
        .target(
            name: "JohnnyScreenSaver",
            dependencies: [
                .product(name: "JohnnyResources",     package: "JohnnyResources"),
                .product(name: "JohnnyEngine",        package: "JohnnyEngine"),
                .product(name: "JohnnyMetalRenderer", package: "JohnnyMetalRenderer"),
                .product(name: "JohnnyDebug",         package: "JohnnyDebug"),
            ],
            path: "Sources/JohnnyScreenSaver",
            linkerSettings: [
                // Produce a Mach-O MH_BUNDLE (the format CFBundle expects).
                // Without this, SwiftPM emits a regular dylib which the
                // legacyScreenSaver host won't load as a plugin.
                .unsafeFlags([
                    "-Xlinker", "-bundle",
                    "-Xlinker", "-undefined",
                    "-Xlinker", "dynamic_lookup",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
