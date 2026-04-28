// JohnnyDebug
//
// SwiftUI overlay (frame stepper, scene picker, current scene/tick
// readout, "force date" picker for holiday testing). Reused by the
// JohnnyDebugApp host and (gated by a settings flag) by the .saver
// itself for in-the-wild diagnosis.
//
// Phase 0: skeleton only. Phase 5 brings the SwiftUI overlay, scene
// picker, frame stepper, and force-date controls.

import Foundation
import JohnnyEngine
import JohnnyMetalRenderer

/// Module marker. Replaced in Phase 5 by the real debug overlay API.
public enum JohnnyDebug {
    /// Semantic version of the debug module.
    public static let version = "0.0.0-phase0"

    /// Verifies dependencies on JohnnyEngine and JohnnyMetalRenderer
    /// resolve correctly.
    public static var dependencyVersions: (engine: String, renderer: String) {
        (JohnnyEngine.version, JohnnyMetalRenderer.version)
    }
}
