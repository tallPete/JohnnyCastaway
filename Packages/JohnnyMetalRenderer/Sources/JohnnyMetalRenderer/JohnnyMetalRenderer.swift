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
