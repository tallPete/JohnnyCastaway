// swift-tools-version: 6.0
//
// JohnnyDebugApp — daily-driver development host for JohnnyEngine.
//
// Builds as a SwiftUI macOS App (@main, SwiftUI App lifecycle).
// The Info.plist is embedded directly into the Mach-O binary via a
// __TEXT,__info_plist section so the process behaves as a first-class
// macOS GUI app (Retina Metal rendering, proper UserDefaults domain,
// NSOpenPanel support) without requiring an .xcodeproj.
//
// Running in Xcode:
//   Open JohnnyCastaway.xcworkspace (not this Package.swift directly).
//   Select the "JohnnyDebugApp" scheme in the scheme picker.
//   Cmd+R.  On first launch: File > Open Resources… to locate
//   RESOURCE.MAP and RESOURCE.001.  The path is saved in UserDefaults.

import PackageDescription

// Absolute path to this Package.swift, resolved at manifest-parse time.
// #filePath is e.g. "/Users/…/Apps/JohnnyDebugApp/Package.swift"; we
// strip the trailing "/Package.swift" to get the package root directory.
// This path is used for the Info.plist linker flag and is valid under
// both `swift build` and Xcode's DerivedData build system.
let packageDir: String = {
    let fp     = String(describing: #filePath)
    let suffix = "/Package.swift"
    return fp.hasSuffix(suffix) ? String(fp.dropLast(suffix.count)) : fp
}()

let package = Package(
    name: "JohnnyDebugApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JohnnyDebugApp", targets: ["JohnnyDebugApp"]),
    ],
    dependencies: [
        .package(path: "../../Packages/JohnnyResources"),
        .package(path: "../../Packages/JohnnyEngine"),
        .package(path: "../../Packages/JohnnyMetalRenderer"),
        .package(path: "../../Packages/JohnnyDebug"),
    ],
    targets: [
        .executableTarget(
            name: "JohnnyDebugApp",
            dependencies: [
                .product(name: "JohnnyResources",     package: "JohnnyResources"),
                .product(name: "JohnnyEngine",        package: "JohnnyEngine"),
                .product(name: "JohnnyMetalRenderer", package: "JohnnyMetalRenderer"),
                .product(name: "JohnnyDebug",         package: "JohnnyDebug"),
            ],
            path: "Sources/JohnnyDebugApp",
            exclude: ["Resources"],   // excluded from Swift sources; embedded below
            linkerSettings: [
                // Embed Info.plist into the __TEXT,__info_plist Mach-O section.
                // macOS reads this section in lieu of a bundle Info.plist, giving
                // the process a bundle identifier, NSHighResolutionCapable, and the
                // other keys needed for a proper GUI app.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker",
                    "\(packageDir)/Sources/JohnnyDebugApp/Resources/Info.plist",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
