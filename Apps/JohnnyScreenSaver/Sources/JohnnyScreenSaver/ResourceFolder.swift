// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Peter Smith
//
// This file is part of the Johnny Castaway macOS screensaver, a derivative
// work of 'Johnny Reborn' (jc_reborn) by Jeremie Guillaume.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file or <https://www.gnu.org/licenses/>.

// ResourceFolder.swift
//
// Persists the user's chosen Sierra resource folder path and other
// settings in ScreenSaverDefaults.  On macOS Sonoma/Tahoe each process
// runs in its own sandbox container, so ScreenSaverDefaults writes from
// System Settings land in a different plist than legacyScreenSaver reads.
// Settings changes are bridged via distributed notifications — picked up
// immediately when legacyScreenSaver is already running, and read from
// legacyScreenSaver's own ScreenSaverDefaults on the next activation otherwise.
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

    // ---------------------------------------------------------------
    // MARK: Cross-process settings bridge
    // ---------------------------------------------------------------
    //
    // On macOS Tahoe the screensaver pipeline involves three separate processes:
    //
    //   System Settings → Wallpaper-Settings.extension  (hosts our configure sheet)
    //                    → legacyScreenSaver[preview]   (small Wallpaper panel preview)
    //   WallpaperAgent  → legacyScreenSaver[wallpaper]  (always-on wallpaper preview)
    //
    // ScreenSaverDefaults are sandbox-scoped, so the configure sheet's writes
    // never reach either legacyScreenSaver instance.  We bridge with a
    // distributed notification, but macOS silently strips userInfo from
    // notifications sent by sandboxed processes.  Instead we encode
    // "key|type:value" in the notification's object field (a plain NSString),
    // which IS preserved across sandbox boundaries.
    //
    // When a legacyScreenSaver instance receives the notification it:
    //   1. Writes the value to its own sharedDefaults (in-memory + CFPreferences flush)
    //   2. Also writes directly to its ByHost plist file so the value survives
    //      the process being killed and restarted when Options is dismissed.

    /// Distributed-notification name posted when any configure-sheet setting changes.
    static let settingsChangedNotification = Notification.Name("nz.petesmith.JohnnyScreenSaver.settingsChanged")

    /// Post a distributed notification so all running legacyScreenSaver instances
    /// pick up the new value immediately.  Key+value are encoded as
    /// "key|type:value" in the notification's object field because macOS strips
    /// userInfo from distributed notifications sent by sandboxed processes.
    private static func bridgeToPeerProcesses(key: String, value: Any) {
        // Encode value with a type tag so the receiver can reconstruct it.
        let valueStr: String
        switch value {
        case let b as Bool:   valueStr = "bool:\(b)"
        case let d as Double: valueStr = "double:\(d)"
        case let i as Int:    valueStr = "int:\(i)"
        case let s as String: valueStr = "str:\(s)"
        default:              valueStr = "str:\(value)"
        }
        let payload = "\(key)|\(valueStr)"
        DistributedNotificationCenter.default().postNotificationName(
            settingsChangedNotification,
            object: payload,
            userInfo: nil,
            deliverImmediately: true
        )
        NSLog("[Johnny] ResourceFolder: posted notification payload=%@", payload)
    }

    /// Decode the payload from a received distributed notification and persist
    /// the new value into the local ScreenSaverDefaults.  Called from
    /// JohnnyScreenSaverView when running inside legacyScreenSaver.
    ///
    /// Also writes directly to the ByHost plist so the value survives
    /// legacyScreenSaver being killed and restarted when Options is closed.
    static func applyNotification(_ notification: Notification) {
        guard let payload = notification.object as? String else {
            NSLog("[Johnny] ResourceFolder: applyNotification — no object payload (userInfo stripped by sandbox)")
            return
        }
        let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            NSLog("[Johnny] ResourceFolder: applyNotification — malformed payload: %@", payload)
            return
        }
        let key      = parts[0]
        let valueStr = parts[1]
        let value: Any
        if      valueStr == "bool:true"                                              { value = true  }
        else if valueStr == "bool:false"                                             { value = false }
        else if valueStr.hasPrefix("double:"), let d = Double(valueStr.dropFirst(7)) { value = d     }
        else if valueStr.hasPrefix("int:"),    let i = Int(valueStr.dropFirst(4))    { value = i     }
        else if valueStr.hasPrefix("str:")                                           { value = String(valueStr.dropFirst(4)) }
        else                                                                         { value = valueStr }

        sharedDefaults.set(value, forKey: key)
        flushPreferences()
        // Belt-and-suspenders: also write directly to the ByHost plist file.
        // flushPreferences() may not complete before macOS kills the preview
        // process on Options-sheet close; a direct atomic file write survives.
        writeToOwnByHostPlist(key: key, value: value)
        NSLog("[Johnny] ResourceFolder: applied key=%@ value=%@", key, "\(value)")
    }

    /// Force a bidirectional sync with cfprefsd: flushes pending in-process writes
    /// to disk and re-reads any values that were changed externally (e.g. by a
    /// previous legacyScreenSaver instance that wrote via writeToOwnByHostPlist).
    /// Call this at the start of startupIfNeeded() so that settings read during
    /// startup reflect values written by the previous process before it was killed.
    static func flushPreferences() {
        let id = Bundle(for: JohnnyScreenSaverView.self).bundleIdentifier
                     ?? "nz.petesmith.JohnnyScreenSaver"
        CFPreferencesSynchronize(id as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    /// Write key=value atomically to our own ByHost plist.
    /// Effective only when called from within legacyScreenSaver (our own container).
    private static func writeToOwnByHostPlist(key: String, value: Any) {
        let byHostDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver" +
                "/Data/Library/Preferences/ByHost"
            )
        let bundleID = "nz.petesmith.JohnnyScreenSaver"
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: byHostDir, includingPropertiesForKeys: nil
        ), let plistURL = files.first(where: {
            $0.lastPathComponent.hasPrefix(bundleID) && $0.pathExtension == "plist"
        }) else {
            NSLog("[Johnny] ResourceFolder: writeToOwnByHostPlist — plist not found")
            return
        }
        do {
            var dict: [String: Any] = (try? Data(contentsOf: plistURL)).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
            } ?? [:]
            dict[key] = value
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            NSLog("[Johnny] ResourceFolder: writeToOwnByHostPlist — wrote %@=%@", key, "\(value)")
        } catch {
            NSLog("[Johnny] ResourceFolder: writeToOwnByHostPlist — failed: %@", error.localizedDescription)
        }
    }

    // Multi-day-arc persistence: written every time the engine advances
    // a sequence (so the user's progress through Sierra's 11-day story
    // survives across screensaver activations).  See "Story-arc
    // persistence" section below.
    private static let progressDayKey     = "ProgressStoryDay"        // Int; 1–11
    private static let progressCalDayKey  = "ProgressLastCalendarDay" // Int; day-of-year, -1 = unset

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
                            flushPreferences()
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

    /// The folder whose security scope is currently active (set by a
    /// successful `resolve()` in legacyScreenSaver).  Diagnostics can write
    /// here because the sandbox token granting access is held for the
    /// lifetime of the running screensaver.  Nil before resolve() succeeds.
    static var activeFolderURL: URL? { activeSecurityScopedURL }

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

        flushPreferences()
        NSLog("[Johnny] ResourceFolder.save: saved path=%@", url.path)
    }

    /// Whether the user has sound enabled.
    ///
    /// Defaults to `false` (absent key → off).  The Tahoe legacy
    /// screensaver host has known issues where Settings' preview
    /// process can be left orphaned after the user closes Settings,
    /// continuing to play audio in the background.  Defaulting sound
    /// off means new users never encounter that surprise; they can
    /// opt in from the configure sheet once they understand the
    /// trade-off.
    static var soundEnabled: Bool {
        get {
            // UserDefaults.bool(forKey:) returns false for a missing key,
            // which is now what we want anyway — but we keep the explicit
            // object-presence check for clarity and so the default can be
            // adjusted in one place.
            guard sharedDefaults.object(forKey: soundEnabledKey) != nil else { return false }
            return sharedDefaults.bool(forKey: soundEnabledKey)
        }
        set {
            sharedDefaults.set(newValue, forKey: soundEnabledKey)
            flushPreferences()
            bridgeToPeerProcesses(key: soundEnabledKey, value: newValue)
            NSLog("[Johnny] ResourceFolder.soundEnabled = %d", newValue ? 1 : 0)
        }
    }

    /// Forget the saved folder (and any active security scope).
    static func clear() {
        stopAccessing()
        sharedDefaults.removeObject(forKey: pathKey)
        sharedDefaults.removeObject(forKey: bookmarkKey)
        flushPreferences()
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
            flushPreferences()
            bridgeToPeerProcesses(key: animationSpeedKey, value: newValue)
        }
    }

    /// Story-day override.  0 means auto (calendar-driven).  1–30 = pinned day.
    static var forceStoryDay: Int {
        get { sharedDefaults.integer(forKey: storyDayKey) }
        set {
            sharedDefaults.set(newValue, forKey: storyDayKey)
            flushPreferences()
            bridgeToPeerProcesses(key: storyDayKey, value: newValue)
        }
    }

    /// Force-holiday override.  0=Off (use calendar), 1=Halloween,
    /// 2=St Patrick, 3=Christmas, 4=New Year.
    static var forceHoliday: Int {
        get { sharedDefaults.integer(forKey: forceHolidayKey) }
        set {
            sharedDefaults.set(newValue, forKey: forceHolidayKey)
            flushPreferences()
            bridgeToPeerProcesses(key: forceHolidayKey, value: newValue)
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
            flushPreferences()
            bridgeToPeerProcesses(key: fidelityModeKey, value: newValue.rawValue)
        }
    }

    /// Whether the debug overlay (HUD with day/tick/threads/sample) is shown.
    static var debugOverlayEnabled: Bool {
        get { sharedDefaults.bool(forKey: debugOverlayKey) }
        set {
            sharedDefaults.set(newValue, forKey: debugOverlayKey)
            flushPreferences()
            bridgeToPeerProcesses(key: debugOverlayKey, value: newValue)
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
    // MARK: Story-arc persistence
    // ---------------------------------------------------------------
    //
    // Sierra's original Johnny Castaway has an 11-day story arc — the
    // raft grows over the days, eventually Johnny leaves the island,
    // and the cycle restarts.  The original game persisted the
    // current day and last-modified-date in CASTAWAY.INI; jc_reborn
    // does the same in a config file.  We persist them in
    // ScreenSaverDefaults so the arc survives across screensaver
    // activations (each activation creates a fresh StoryRunner — without
    // persistence, every session would start at day 1).
    //
    // The host writes progress after every successful beginNextSequence
    // call, but only when forceStoryDay is unset — we don't let a
    // temporary diagnostic override pollute the natural-progression state.

    /// The persisted story day from a prior activation, or 1 if unset.
    /// Clamped to `[1, 11]` defensively.
    static var persistedStoryDay: Int {
        guard sharedDefaults.object(forKey: progressDayKey) != nil else { return 1 }
        let raw = sharedDefaults.integer(forKey: progressDayKey)
        return max(1, min(11, raw))
    }

    /// The persisted day-of-year when the story day was last advanced,
    /// or `-1` (sentinel: "no prior record") if unset.
    static var persistedLastCalendarDay: Int {
        guard sharedDefaults.object(forKey: progressCalDayKey) != nil else { return -1 }
        return sharedDefaults.integer(forKey: progressCalDayKey)
    }

    /// Save the engine's natural-progression state for the next activation.
    /// Called after `beginNextSequence`; cheap (≤ once per ~30 s).
    static func saveStoryProgress(day: Int, lastCalendarDay: Int) {
        sharedDefaults.set(day,             forKey: progressDayKey)
        sharedDefaults.set(lastCalendarDay, forKey: progressCalDayKey)
        flushPreferences()
    }

    /// Reset the persisted story arc.  Not currently surfaced in the
    /// configure sheet — exposed for future "Restart story" button.
    static func clearStoryProgress() {
        sharedDefaults.removeObject(forKey: progressDayKey)
        sharedDefaults.removeObject(forKey: progressCalDayKey)
        flushPreferences()
        NSLog("[Johnny] ResourceFolder.clearStoryProgress: done")
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
