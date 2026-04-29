// ResourceFolder.swift
//
// Persists the user's chosen Sierra resource folder via a security-
// scoped bookmark stored in ScreenSaverDefaults. The .saver runs
// inside the legacyScreenSaver host process, which is sandboxed —
// arbitrary file paths won't work, but Powerbox grants per-URL
// access via NSOpenPanel and that access can be persisted across
// process restarts via security-scoped bookmarks.
//
// Flow:
//   1. Configure sheet calls openPanel() → user picks a folder
//   2. We create a bookmark with .withSecurityScope and store it
//   3. On saver start, resolve() unpacks the bookmark and starts
//      access. Caller must call stopAccessingSecurityScopedResource()
//      in teardown to release.

import Foundation
import AppKit
import ScreenSaver

enum ResourceFolder {

    private static let bookmarkKey = "ResourceFolderBookmark"
    private static let pathHintKey = "ResourceFolderPath"  // for display only

    private static var defaults: UserDefaults {
        ScreenSaverDefaults(forModuleWithName: bundleID) ?? .standard
    }

    private static var bundleID: String {
        Bundle(for: JohnnyScreenSaverView.self).bundleIdentifier
            ?? "nz.petesmith.JohnnyScreenSaver"
    }

    /// Resolve the saved bookmark, start access, and return the URL.
    /// Returns nil if no bookmark is set or it can't be resolved.
    /// Caller is responsible for calling
    /// `url.stopAccessingSecurityScopedResource()` on teardown.
    static func resolve() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else {
            return nil
        }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else {
                NSLog("[Johnny] bookmark resolved but access denied")
                return nil
            }
            if stale {
                // Rebuild the bookmark for next time
                if let newData = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    defaults.set(newData, forKey: bookmarkKey)
                    defaults.synchronize()
                }
            }
            return url
        } catch {
            NSLog("[Johnny] failed to resolve bookmark: \(error)")
            return nil
        }
    }

    /// The display path of the configured folder (for the settings
    /// sheet's "currently configured: …" label). Doesn't grant access.
    static var displayPath: String? {
        defaults.string(forKey: pathHintKey)
    }

    /// Persist a bookmark to the user-picked folder.
    /// Verifies the folder contains the expected RESOURCE.MAP /
    /// RESOURCE.001 files first; throws if they're missing so the
    /// settings sheet can surface an error.
    static func save(folder url: URL) throws {
        let mapURL  = url.appendingPathComponent("RESOURCE.MAP")
        let dataURL = url.appendingPathComponent("RESOURCE.001")
        let fm = FileManager.default
        guard fm.fileExists(atPath: mapURL.path) else {
            throw FolderError.missingFile("RESOURCE.MAP")
        }
        guard fm.fileExists(atPath: dataURL.path) else {
            throw FolderError.missingFile("RESOURCE.001")
        }
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: bookmarkKey)
        defaults.set(url.path, forKey: pathHintKey)
        defaults.synchronize()
    }

    /// Forget the saved folder.
    static func clear() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: pathHintKey)
        defaults.synchronize()
    }

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
