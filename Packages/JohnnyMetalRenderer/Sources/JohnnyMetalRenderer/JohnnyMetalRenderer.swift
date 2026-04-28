// JohnnyMetalRenderer
//
// Uploads JohnnyEngine's 640×480 indexed framebuffer as a Metal
// texture and renders to a CAMetalLayer with nearest-neighbour
// integer scaling. Fragment shader samples a 16-entry RGBA palette
// LUT at the indexed value to produce final pixel colour.
//
// Phase 0: skeleton only. Phase 4 brings the Metal pipeline, palette
// LUT shader, integer-scale letterboxing, and CAMetalLayer host.

import Foundation
import JohnnyEngine

/// Module marker. Replaced in Phase 4 by the real renderer API.
public enum JohnnyMetalRenderer {
    /// Semantic version of the renderer module.
    public static let version = "0.0.0-phase0"

    /// Verifies the dependency on JohnnyEngine resolves correctly.
    public static var engineVersion: String {
        JohnnyEngine.version
    }
}
