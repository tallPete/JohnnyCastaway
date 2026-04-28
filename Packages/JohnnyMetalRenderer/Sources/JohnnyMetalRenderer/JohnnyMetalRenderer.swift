// JohnnyMetalRenderer
//
// Uploads JohnnyEngine's 640×480 indexed framebuffer as an R8Uint Metal
// texture and renders to a CAMetalLayer with nearest-neighbour integer
// scaling. A 16×1 RGBA8Unorm palette LUT texture is sampled in the
// fragment shader to expand palette indices to RGB.
//
// Public API:
//   EngineRenderer    — Core renderer: init(device:), update(framebuffer:palette:),
//                       render(to:drawableSize:). No AppKit dependency.
//   JohnnyMetalView   — NSView subclass (AppKit) with CAMetalLayer backing and
//                       CADisplayLink tick loop. Set .engine to drive it.
//   RendererError     — Thrown by EngineRenderer.init on GPU/shader failure.
//
// Shaders:
//   Embedded as a Swift string in ShaderSource.swift; compiled at init time
//   via MTLDevice.makeLibrary(source:options:). No .metallib bundle resource
//   needed for the SwiftPM package. The .saver target (Phase 6) may opt into
//   a pre-compiled metallib via Bundle.module for faster launch.

import Foundation
import JohnnyEngine

/// Module marker.
public enum JohnnyMetalRenderer {
    /// Semantic version of the renderer module.
    public static let version = "0.0.0-phase4"

    /// Version of the JohnnyEngine dependency.
    public static var engineVersion: String {
        JohnnyEngine.version
    }
}
