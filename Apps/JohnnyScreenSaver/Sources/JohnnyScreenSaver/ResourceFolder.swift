// ResourceFolder.swift
//
// Persists the user's chosen Sierra resource folder path in
// ScreenSaverDefaults.  Both the System Settings preview pane (running
// in the System Settings process) and the full-screen legacyScreenSaver
// process use the same ScreenSaverDefaults plist file keyed by bundle ID,
// so a path saved in one is visible in the other.
//
// We intentionally do NOT use security-scoped bookmarks:
//   • Security-scoped bookmarks are tied to the sandbox of the
//     *creating* application.  A bookmark created in System Settings
//     cannot be resolved in legacyScreenSaver — they are separate
//     sandbox containers — so resolve() would silently return nil on
//     every legacyScreenSaver launch even though the data was written.
//   • legacyScreenSaver on modern macOS has read access to the user's
//     home directory, so a plain-path URL returned from NSOpenPanel
//     works without any bookmark machinery.
//
// Flow:
//   1. Configure sheet / first-run panel opens NSOpenPanel; user picks
//      a folder.
//   2. save(folder:) validates the folder and stores the plain path.
//   3. resolve() returns the stored URL if the folder still exists and
//      contains RESOURCE.MAP.

import Foundation
import AppKit
import ScreenSaver

enum ResourceFolder {

    private static let pathKey = "ResourceFolderPath"

    // Cache the defaults object.  ScreenSaverDefaults(forModuleWithName:)
    // can return nil if called before the bundle is registered; the lazy
    // initialiser runs on first access, which is always after init().
    // UserDefaults is internally thread-safe; nonisolated(unsafe) satisfies
    // Swift 6's mutable-global-variable check without adding actor overhead.
    private nonisolated(unsafe) static let sharedDefaults: UserDefaults = {
        let id = Bundle(for: JohnnyScreenSaverView.self).bundleIdentifier
                     ?? "nz.petesmith.JohnnyScreenSaver"
        NSLog("[Johnny] ResourceFolder: opening ScreenSaverDefaults for '%@'", id)
        if let sd = ScreenSaverDefaults(forModuleWithName: id) {
            NSLog("[Johnny] ResourceFolder: ScreenSaverDefaults OK")
            return sd
        }
        NSLog("[Johnny] ResourceFolder: ScreenSaverDefaults returned nil — falling back to UserDefaults.standard")
        return .standard
    }()

    // ---------------------------------------------------------------
    // MARK: Public API
    // ---------------------------------------------------------------

    /// Return the URL of the configured resource folder if it exists
    /// and contains RESOURCE.MAP.  Returns nil if not configured or
    /// the folder has been moved / deleted.
    static func resolve() -> URL? {
        guard let path = sharedDefaults.string(forKey: pathKey) else {
            NSLog("[Johnny] ResourceFolder.resolve: no path in defaults")
            return nil
        }
        NSLog("[Johnny] ResourceFolder.resolve: stored path = %@", path)
        let url    = URL(fileURLWithPath: path)
        let mapURL = url.appendingPathComponent("RESOURCE.MAP")
        guard FileManager.default.fileExists(atPath: mapURL.path) else {
            NSLog("[Johnny] ResourceFolder.resolve: RESOURCE.MAP not found at %@", mapURL.path)
            return nil
        }
        NSLog("[Johnny] ResourceFolder.resolve: folder OK → %@", url.path)
        return url
    }

    /// The display path of the configured folder (for the settings
    /// sheet's "currently configured: …" label).  Does not validate.
    static var displayPath: String? {
        sharedDefaults.string(forKey: pathKey)
    }

    /// Persist the user-picked folder path.
    ///
    /// Validates that RESOURCE.MAP and RESOURCE.001 are present;
    /// throws ``FolderError`` if either is missing.
    static func save(folder url: URL) throws {
        NSLog("[Johnny] ResourceFolder.save: validating %@", url.path)
        let fm = FileManager.default
        let mapURL  = url.appendingPathComponent("RESOURCE.MAP")
        let dataURL = url.appendingPathComponent("RESOURCE.001")
        guard fm.fileExists(atPath: mapURL.path)  else { throw FolderError.missingFile("RESOURCE.MAP")  }
        guard fm.fileExists(atPath: dataURL.path) else { throw FolderError.missingFile("RESOURCE.001") }
        sharedDefaults.set(url.path, forKey: pathKey)
        let ok = sharedDefaults.synchronize()
        NSLog("[Johnny] ResourceFolder.save: saved path=%@ synchronize()=%d", url.path, ok ? 1 : 0)
    }

    /// Forget the saved folder.
    static func clear() {
        sharedDefaults.removeObject(forKey: pathKey)
        sharedDefaults.synchronize()
        NSLog("[Johnny] ResourceFolder.clear: done")
    }

    // ---------------------------------------------------------------
    // MARK: Errors
    // ---------------------------------------------------------------

    enum FolderError: LocalizedError {
        case missingFile(String)
        var errorDescription: String? {
            switch self {
            case .missingFile(let name):
                return "Folder is missing \(name). Pick the folder that contains both RESOURCE.MAP and RESOURCE.001."
            }
        }
    }
}
