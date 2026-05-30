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
// any later version. See the COPYING file or <https://www.gnu.org/licenses/>.

// JohnnyDebugApp.swift
//
// @main entry point — SwiftUI App lifecycle.
//
// Architecture:
//   AppState      — @Observable singleton that loads resources, owns the
//                   Engine + StoryRunner, and wires up EngineDebugState.
//   ContentView   — Switches between ResourceLocatorView (no resources)
//                   and DebugView (engine running).
//   DebugView     — ZStack: MetalLayerView (bottom) + DebugOverlayView (top).
//   MetalLayerView — NSViewRepresentable wrapping JohnnyMetalView;
//                    wires frameProvider = { appState.debugState.tick() }.

import SwiftUI
import AppKit
import JohnnyResources
import JohnnyEngine
import JohnnyMetalRenderer
import JohnnyDebug

// MARK: - App entry point

@main
struct JohnnyDebugAppEntry: App {

    @State private var appState = AppState()

    init() {
        // Diagnostic: print the running executable path + build time so we
        // can verify (in Xcode's console pane) which binary actually launched
        // when something looks "stale".
        let exe = CommandLine.arguments.first ?? "?"
        let mtime: String = (try? FileManager.default
            .attributesOfItem(atPath: exe)[.modificationDate] as? Date)
            .map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        print("[JohnnyDebugApp] launched: \(exe)")
        print("[JohnnyDebugApp] built:    \(mtime)")
    }

    var body: some Scene {
        WindowGroup("Johnny Castaway Debug") {
            ContentView(appState: appState)
                .frame(minWidth: 800, minHeight: 540)
                .background(.black)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Resources…") {
                    appState.openResourcePanel()
                }
                .keyboardShortcut("o")
            }
        }
    }
}

// MARK: - AppState

/// Owns loading, the engine/runner, and the debug state.
@Observable @MainActor
final class AppState {

    var debugState = EngineDebugState()
    var loadError: String?
    var metalView: JohnnyMetalView?    // set by MetalLayerView.makeNSView

    // Remembered resource folder (UserDefaults key)
    private let resourcePathKey = "JohnnyDebugApp.resourcePath"

    init() {
        // Try to reload from saved path on launch
        if let saved = UserDefaults.standard.string(forKey: resourcePathKey) {
            try? load(from: URL(fileURLWithPath: saved))
        }
    }

    // MARK: - Resource loading

    func openResourcePanel() {
        let panel = NSOpenPanel()
        panel.message        = "Locate the folder containing RESOURCE.MAP and RESOURCE.001"
        panel.prompt         = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try load(from: url)
            UserDefaults.standard.set(url.path, forKey: resourcePathKey)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func load(from folderURL: URL) throws {
        let mapURL       = folderURL.appendingPathComponent("RESOURCE.MAP")
        let containerURL = folderURL.appendingPathComponent("RESOURCE.001")

        let mapData       = try Data(contentsOf: mapURL)
        let containerData = try Data(contentsOf: containerURL)

        let archive = try ResourceArchive.parse(map: mapData, container: containerData)
        let engine      = try Engine(archive: archive, sound: debugState.soundSink)
        let storyRunner = try StoryRunner(archive: archive,
                                          dateProvider: resolvedDateProvider(),
                                          sound: debugState.soundSink)

        debugState.configure(engine: engine, storyRunner: storyRunner)
        loadError = nil

        print(String(format: "[palette] transparent index = %d",
                     storyRunner.palette.transparentIndex))

        // Wire the frame provider on the Metal view (if already created)
        wireFrameProvider()
    }

    /// Build the DateProvider: FixedDateProvider if the debug overlay
    /// has force-date enabled, otherwise SystemDateProvider.
    private func resolvedDateProvider() -> any DateProvider {
        guard debugState.useForceDate else { return SystemDateProvider() }
        let cal   = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: debugState.forcedDate)
        return FixedDateProvider(
            year:  comps.year  ?? 2026,
            month: comps.month ?? 4,
            day:   comps.day   ?? 28
        )
    }

    func wireFrameProvider() {
        metalView?.frameProvider = { [weak self] in
            self?.debugState.tick()
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    var appState: AppState

    var body: some View {
        if appState.debugState.isLoaded {
            DebugView(appState: appState)
        } else {
            ResourceLocatorView(appState: appState)
        }
    }
}

// MARK: - ResourceLocatorView

struct ResourceLocatorView: View {
    var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text("No Resource Files")
                .font(.title2.bold())

            Text("Johnny Castaway requires the original Sierra resource files.\nUse File > Open Resources… to locate the folder\ncontaining RESOURCE.MAP and RESOURCE.001.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let err = appState.loadError {
                Text("Error: \(err)")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Button("Open Resources…") {
                appState.openResourcePanel()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
        }
        .frame(maxWidth: 440)
        .padding(40)
    }
}

// MARK: - DebugView

struct DebugView: View {
    var appState: AppState

    var body: some View {
        ZStack(alignment: .bottom) {
            MetalLayerView(appState: appState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            DebugOverlayView(state: appState.debugState)
        }
        .background(.black)
        .ignoresSafeArea()
    }
}

// MARK: - MetalLayerView

/// NSViewRepresentable wrapping JohnnyMetalView.
/// Wires frameProvider → AppState.debugState.tick() so the debug overlay's
/// pause/step/mode controls drive the engine and renderer in lockstep.
struct MetalLayerView: NSViewRepresentable {
    var appState: AppState

    func makeNSView(context: Context) -> JohnnyMetalView {
        let view = JohnnyMetalView(frame: .zero)
        appState.metalView = view          // register for later re-wiring
        appState.wireFrameProvider()       // wire now if engine already loaded
        return view
    }

    func updateNSView(_ nsView: JohnnyMetalView, context: Context) {
        // Re-wire if the app state has changed (e.g. after resource reload)
        appState.wireFrameProvider()
    }
}
