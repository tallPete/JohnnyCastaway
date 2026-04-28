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
