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

// JohnnyDebug
//
// SwiftUI overlay + observable state model for the JohnnyDebugApp and
// (gated by a settings flag) the .saver itself.
//
// Public API:
//   EngineDebugState   — @Observable @MainActor state: pause/step, scene
//                        picker, fidelity mode, force-date, overlay toggle,
//                        sound readout, thread snapshots. Provides tick()
//                        for JohnnyMetalView.frameProvider.
//   DebugOverlayView   — SwiftUI View to embed over the Metal view.
//
// Usage (debug app):
//   let state = EngineDebugState()
//   state.configure(engine: engine, storyRunner: runner)
//   metalView.frameProvider = { state.tick() }
//   // Embed DebugOverlayView(state: state) over the Metal view.

import Foundation
import JohnnyEngine
import JohnnyMetalRenderer

/// Module marker.
public enum JohnnyDebug {
    /// Semantic version of the debug module.
    public static let version = "0.0.0-phase5"

    /// Versions of the JohnnyEngine and JohnnyMetalRenderer dependencies.
    public static var dependencyVersions: (engine: String, renderer: String) {
        (JohnnyEngine.version, JohnnyMetalRenderer.version)
    }
}
