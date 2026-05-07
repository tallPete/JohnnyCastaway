// ResourceFolder.swift
//
// Persists the user's chosen Sierra resource folder path in
// ScreenSaverDefaults.  Both the System Settings preview pane (running
// in the System Settings process) and the full-screen legacyScreenSaver
// process use the same ScreenSaverDefaults plist file keyed by bundle ID,
// so a path saved in one is visible in the other.
//
// Access model:
//   • The PLAIN PATH (pathKey) is stored in ScreenSaverDefaults for
//     display purposes in the configure sheet.  Plain paths DO NOT work
//     for file I/O inside the sandboxed legacyScreenSaver host process.
//
//   • A SECURITY-SCOPED BOOKMARK (bookmarkKey) is created only when
//     save(folder:) is called from within legacyScreenSaver — identified
//     by ProcessInfo.processInfo.processName containing "legacyScreenSaver".
//     Security-scoped bookmarks are sandbox-scoped to the creating process;
//     a bookmark made in System Settings cannot be resolved by
//     legacyScreenSaver (different sandbox container), so we intentionally
//     do not create one there.
//
// Flow:
//   A. Configure sheet (System Settings / PID 4678):
//      save(folder:) writes pathKey only; bookmarkKey is untouched so
//      that a previously-valid legacyScreenSaver bookmark is not clobbered.
//
//   B. First-run panel (legacyScreenSaver / PID 989):
//      save(folder:) writes pathKey AND creates a .withSecurityScope bookmark
//      stored under bookmarkKey.  On subsequent launches, resolve() finds
//      the bookmark, calls startAccessingSecurityScopedResource(), and
//      returns the URL.
//
//   C. resolve() always tries the bookmark first; if missing or unusable it
//      falls back to the plain path (works in unsandboxed contexts such as
//      tests and the debug app).  stopAccessing() must be called when the
//      screensaver tears down so the kernel sandbox token is released.

import Foundation
import AppKit
import ScreenSaver
import JohnnyEngine

enum ResourceFolder {

    private static let pathKey            = "ResourceFolderPath"
    private static let bookmarkKey        = "ResourceFolderBookmark"
    private static let soundEnabledKey    = "SoundEnabled"
    private static let animationSpeedKey  = "AnimationSpeed"   // Double; 1.0 = faithful
    private static let storyDayKey        = "ForceStoryDay"    // Int; 0 = auto, 1–30 = override
    private static let forceHolidayKey    = "ForceHoliday"     // Int; 0=Off,1=Halloween,2=StPatrick,3=Christmas,4=NewYear
    private static let fidelityModeKey    = "FidelityMode"     // String; "fixed" | "raw"
    private static let debugOverlayKey    = "ShowDebugOverlay" // Bool

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

    /// The URL whose security scope is currently active.
    /// Non-nil only after a successful resolve() in legacyScreenSaver.
    /// Cleared by stopAccessing().
    private nonisolated(unsafe) static var activeSecurityScopedURL: URL? = nil

    // ---------------------------------------------------------------
    // MARK: Public API
    // ---------------------------------------------------------------

    /// Return the URL of the configured resource folder if it exists
    /// and contains RESOURCE.MAP.  Returns nil if not configured or
    /// the folder has been moved / deleted.
    ///
    /// Tries the security-scoped bookmark first (required in the sandboxed
    /// legacyScreenSaver host process).  Falls back to the plain stored
    /// path for unsandboxed contexts (tests, debug app).
    ///
    /// On success in legacyScreenSaver, calls
    /// startAccessingSecurityScopedResource() — call stopAccessing() when
    /// the engine tears down to release the kernel token.
    static func resolve() -> URL? {
        // Short-circuit: return the cached URL if security scope is
        // already active so multiple display instances don't open
        // duplicate sandbox tokens for the same path.
        if let url = activeSecurityScopedURL {
            NSLog("[Johnny] ResourceFolder.resolve: returning active scoped URL %@", url.path)
            return url
        }

        // ---- 1. Try security-scoped bookmark --------------------------------

        if let data = sharedDefaults.data(forKey: bookmarkKey) {
            NSLog("[Johnny] ResourceFolder.resolve: found bookmark data (%d bytes)", data.count)
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: data,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale)
                NSLog("[Johnny] ResourceFolder.resolve: bookmark resolved stale=%d path=%@",
                      isStale ? 1 : 0, url.path)
                let started = url.startAccessingSecurityScopedResource()
                NSLog("[Johnny] ResourceFolder.resolve: startAccessingSecurityScopedResource=%d",
                      started ? 1 : 0)
                let mapURL = url.appendingPathComponent("RESOURCE.MAP")
                if FileManager.default.fileExists(atPath: mapURL.path) {
                    activeSecurityScopedURL = url
                    if isStale {
                        // Renew the bookmark while we still have access.
                        if let newData = try? url.bookmarkData(
                            options: .withSecurityScope,
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        ) {
                            sharedDefaults.set(newData, forKey: bookmarkKey)
                            sharedDefaults.synchronize()
                            NSLog("[Johnny] ResourceFolder.resolve: refreshed stale bookmark")
                        }
                    }
                    NSLog("[Johnny] ResourceFolder.resolve: bookmark OK → %@", url.path)
                    return url
                } else {
                    url.stopAccessingSecurityScopedResource()
                    NSLog("[Johnny] ResourceFolder.resolve: RESOURCE.MAP missing at %@", url.path)
                }
            } catch {
                NSLog("[Johnny] ResourceFolder.resolve: bookmark resolution failed — %@",
                      error.localizedDescription)
            }
        } else {
            NSLog("[Johnny] ResourceFolder.resolve: no bookmark data in defaults")
        }

        // ---- 2. Fall back to plain path (unsandboxed contexts) --------------

        guard let path = sharedDefaults.string(forKey: pathKey) else {
            NSLog("[Johnny] ResourceFolder.resolve: no path in defaults")
            return nil
        }
        NSLog("[Johnny] ResourceFolder.resolve: trying plain path %@", path)
        let url    = URL(fileURLWithPath: path)
        let mapURL = url.appendingPathComponent("RESOURCE.MAP")
        guard FileManager.default.fileExists(atPath: mapURL.path) else {
            NSLog("[Johnny] ResourceFolder.resolve: RESOURCE.MAP not found at plain path")
            return nil
        }
        NSLog("[Johnny] ResourceFolder.resolve: plain path OK → %@", url.path)
        return url
    }

    /// Stop accessing the security-scoped resource started by resolve().
    /// Call from teardown() so the kernel sandbox token is properly released.
    static func stopAccessing() {
        guard let url = activeSecurityScopedURL else { return }
        url.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
        NSLog("[Johnny] ResourceFolder.stopAccessing: done")
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
    ///
    /// When called from legacyScreenSaver (the animation process) a
    /// security-scoped bookmark is also created and stored so that
    /// subsequent launches can regain file access.  When called from
    /// the configure sheet (System Settings), only the plain path is
    /// stored — the existing legacyScreenSaver bookmark (if any) is
    /// intentionally preserved.
    static func save(folder url: URL) throws {
        NSLog("[Johnny] ResourceFolder.save: validating %@", url.path)
        let fm = FileManager.default
        let mapURL  = url.appendingPathComponent("RESOURCE.MAP")
        let dataURL = url.appendingPathComponent("RESOURCE.001")
        guard fm.fileExists(atPath: mapURL.path)  else { throw FolderError.missingFile("RESOURCE.MAP")  }
        guard fm.fileExists(atPath: dataURL.path) else { throw FolderError.missingFile("RESOURCE.001") }

        // Always store the plain path for display + unsandboxed fallback.
        sharedDefaults.set(url.path, forKey: pathKey)

        // Create a security-scoped bookmark only when we are inside
        // legacyScreenSaver.  The bookmark is tied to the sandbox of the
        // creating process; a bookmark made in System Settings cannot be
        // resolved here.  We detect the context by process name rather than
        // trying to create the bookmark and handling the error, so that we
        // never inadvertently overwrite a valid existing bookmark with an
        // unusable one from a different sandbox context.
        let procName = ProcessInfo.processInfo.processName
        NSLog("[Johnny] ResourceFolder.save: processName=%@", procName)

        if procName.lowercased().contains("legacyscreensaver") {
            do {
                let data = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                sharedDefaults.set(data, forKey: bookmarkKey)
                NSLog("[Johnny] ResourceFolder.save: security-scoped bookmark created (%d bytes)", data.count)
                // Invalidate the active-URL cache: next resolve() will re-resolve
                // the fresh bookmark and call startAccessingSecurityScopedResource.
                activeSecurityScopedURL = nil
            } catch {
                // Unexpected — log and continue.  Do NOT clear bookmarkKey so a
                // previous valid bookmark is not lost.
                NSLog("[Johnny] ResourceFolder.save: bookmark creation failed — %@",
                      error.localizedDescription)
            }
        } else {
            // Configure sheet / other context: leave bookmarkKey untouched.
            NSLog("[Johnny] ResourceFolder.save: non-legacyScreenSaver context — bookmark unchanged")
        }

        let ok = sharedDefaults.synchronize()
        NSLog("[Johnny] ResourceFolder.save: saved path=%@ synchronize()=%d", url.path, ok ? 1 : 0)
    }

    /// Whether the user has sound enabled.
    ///
    /// Defaults to `true` (absent key → on) so sounds work out of the
    /// box before the configure sheet is set up.
    static var soundEnabled: Bool {
        get {
            // UserDefaults.bool(forKey:) returns false for a missing key,
            // but we want the default to be true.
            guard sharedDefaults.object(forKey: soundEnabledKey) != nil else { return true }
            return sharedDefaults.bool(forKey: soundEnabledKey)
        }
        set {
            sharedDefaults.set(newValue, forKey: soundEnabledKey)
            sharedDefaults.synchronize()
            NSLog("[Johnny] ResourceFolder.soundEnabled = %d", newValue ? 1 : 0)
        }
    }

    /// Forget the saved folder (and any active security scope).
    static func clear() {
        stopAccessing()
        sharedDefaults.removeObject(forKey: pathKey)
        sharedDefaults.removeObject(forKey: bookmarkKey)
        sharedDefaults.synchronize()
        NSLog("[Johnny] ResourceFolder.clear: done")
    }

    // ---------------------------------------------------------------
    // MARK: Phase 6 settings (§2.4)
    // ---------------------------------------------------------------

    /// Animation speed multiplier; 1.0 = faithful pacing.
    /// Allowed values surfaced to UI: 0.5, 1.0, 1.5, 2.0.
    static var animationSpeed: Double {
        get {
            guard sharedDefaults.object(forKey: animationSpeedKey) != nil else { return 1.0 }
            let v = sharedDefaults.double(forKey: animationSpeedKey)
            return v > 0 ? v : 1.0
        }
        set {
            sharedDefaults.set(newValue, forKey: animationSpeedKey)
            sharedDefaults.synchronize()
        }
    }

    /// Story-day override.  0 means auto (calendar-driven).  1–30 = pinned day.
    static var forceStoryDay: Int {
        get { sharedDefaults.integer(forKey: storyDayKey) }
        set {
            sharedDefaults.set(newValue, forKey: storyDayKey)
            sharedDefaults.synchronize()
        }
    }

    /// Force-holiday override.  0=Off (use calendar), 1=Halloween,
    /// 2=St Patrick, 3=Christmas, 4=New Year.
    static var forceHoliday: Int {
        get { sharedDefaults.integer(forKey: forceHolidayKey) }
        set {
            sharedDefaults.set(newValue, forKey: forceHolidayKey)
            sharedDefaults.synchronize()
        }
    }

    /// Engine fidelity mode (`.fixed` = Go-port corrections, `.raw` = jc_reborn).
    static var fidelityMode: FidelityMode {
        get {
            guard let raw = sharedDefaults.string(forKey: fidelityModeKey),
                  let mode = FidelityMode(rawValue: raw) else { return .fixed }
            return mode
        }
        set {
            sharedDefaults.set(newValue.rawValue, forKey: fidelityModeKey)
            sharedDefaults.synchronize()
        }
    }

    /// Whether the debug overlay (HUD with day/tick/threads/sample) is shown.
    static var debugOverlayEnabled: Bool {
        get { sharedDefaults.bool(forKey: debugOverlayKey) }
        set {
            sharedDefaults.set(newValue, forKey: debugOverlayKey)
            sharedDefaults.synchronize()
        }
    }

    // ---------------------------------------------------------------
    // MARK: Holiday-date synthesis (for forceHoliday)
    // ---------------------------------------------------------------

    /// Construct a Date that falls inside the holiday window for the
    /// given holiday code (1–4).  Year is the current year so the engine's
    /// day/night calculation uses a sensible local time.  Returns nil for
    /// `holiday == 0` (use real calendar instead).
    static func dateForForcedHoliday(_ holiday: Int) -> Date? {
        guard holiday >= 1 && holiday <= 4 else { return nil }
        var comps = Calendar.current.dateComponents([.year, .hour], from: Date())
        comps.hour = 12  // mid-day → guaranteed not "night"
        switch holiday {
        case 1: comps.month = 10; comps.day = 31  // Halloween
        case 2: comps.month =  3; comps.day = 17  // St Patrick
        case 3: comps.month = 12; comps.day = 24  // Christmas (Dec 23–25 window)
        case 4: comps.month = 12; comps.day = 31  // New Year (Dec 29–Jan 1 window)
        default: return nil
        }
        return Calendar.current.date(from: comps)
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
