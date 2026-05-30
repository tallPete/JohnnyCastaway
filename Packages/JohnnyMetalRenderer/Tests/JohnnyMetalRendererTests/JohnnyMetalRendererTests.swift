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

// JohnnyMetalRendererTests.swift
//
// Phase 4 tests for JohnnyMetalRenderer.
//
// Two groups:
//   • Pure-logic tests (no GPU) — gameRect letterboxing math; always run.
//   • GPU-dependent tests — guarded by MTLCreateSystemDefaultDevice().
//     Pass on any Mac with a Metal-capable GPU (all Macs since 2012);
//     silently skip on headless / no-GPU environments.
//
// The strict pixel-identical rendering comparison (plan §5, item 2) is
// deferred to Phase 7 once jc_reborn PNG fixtures are committed.

import Testing
import Metal
import QuartzCore
import CoreGraphics
import JohnnyEngine
@testable import JohnnyMetalRenderer

// MARK: - Module-level tests

@Suite("JohnnyMetalRenderer module")
struct JohnnyMetalRendererModuleTests {

    @Test("Version marker is phase4")
    func versionMarker() {
        #expect(JohnnyMetalRenderer.version == "0.0.0-phase4")
    }

    @Test("Engine dependency version is phase3")
    func engineDependency() {
        #expect(JohnnyMetalRenderer.engineVersion == "0.0.0-phase3")
    }
}

// MARK: - gameRect letterboxing (no GPU required)

infix operator ≈ : ComparisonPrecedence
/// Float equality within a small epsilon (used in gameRect unit tests).
private func ≈ (lhs: Float, rhs: Float) -> Bool { abs(lhs - rhs) < 0.001 }

@Suite("EngineRenderer.gameRect letterboxing")
struct GameRectTests {

    // MARK: Exact fit — no letterbox

    @Test("640×480: 1× scale fills entire NDC")
    func exactFit() {
        let r = EngineRenderer.gameRect(for: CGSize(width: 640, height: 480))
        #expect(r.x ≈ -1.0, "left = -1")
        #expect(r.z ≈  1.0, "right = +1")
        #expect(r.y ≈  1.0, "top = +1")
        #expect(r.w ≈ -1.0, "bottom = -1")
    }

    @Test("1280×960: 2× scale fills entire NDC")
    func doubleScale() {
        let r = EngineRenderer.gameRect(for: CGSize(width: 1280, height: 960))
        #expect(r.x ≈ -1.0)
        #expect(r.z ≈  1.0)
        #expect(r.y ≈  1.0)
        #expect(r.w ≈ -1.0)
    }

    @Test("Integer-scale drawables (3×, 4×) fill NDC exactly")
    func integerScales() {
        for scale in [3.0, 4.0] {
            let r = EngineRenderer.gameRect(for: CGSize(width: 640 * scale,
                                                        height: 480 * scale))
            #expect(r.x ≈ -1.0, "Scale \(scale)×: left should be -1")
            #expect(r.z ≈  1.0, "Scale \(scale)×: right should be +1")
            #expect(r.y ≈  1.0, "Scale \(scale)×: top should be +1")
            #expect(r.w ≈ -1.0, "Scale \(scale)×: bottom should be -1")
        }
    }

    // MARK: 1080p — fractional fill, height-limited

    @Test("1920×1080: fractional 2.25× fills height, horizontal letterbox only")
    func hdResolution() {
        // k = min(1920/640, 1080/480) = min(3.0, 2.25) = 2.25
        // gw = 1440, gh = 1080; ox = 240, oy = 0
        let r = EngineRenderer.gameRect(for: CGSize(width: 1920, height: 1080))
        let expLeft   = Float(240.0  / 1920.0 * 2.0 - 1.0)   // -0.75
        let expRight  = Float(1680.0 / 1920.0 * 2.0 - 1.0)   //  0.75
        #expect(r.x ≈ expLeft,  "left (horizontal letterbox)")
        #expect(r.z ≈ expRight, "right")
        #expect(r.y ≈ 1.0, "no top margin — height fully used")
        #expect(r.w ≈ -1.0, "no bottom margin — height fully used")
    }

    @Test("3840×2160 (4K): fractional 4.5× fills height edge-to-edge")
    func uhd4KResolution() {
        // k = min(3840/640, 2160/480) = min(6.0, 4.5) = 4.5
        // gw = 2880, gh = 2160; ox = 480, oy = 0
        let r = EngineRenderer.gameRect(for: CGSize(width: 3840, height: 2160))
        let expLeft  = Float(480.0  / 3840.0 * 2.0 - 1.0)    // -0.75
        let expRight = Float(3360.0 / 3840.0 * 2.0 - 1.0)    //  0.75
        #expect(r.x ≈ expLeft,  "left (horizontal letterbox)")
        #expect(r.z ≈ expRight, "right")
        #expect(r.y ≈ 1.0,  "no top margin — height fully used")
        #expect(r.w ≈ -1.0, "no bottom margin — height fully used")
    }

    // MARK: Horizontal letterbox (wide display, height limits scale)

    @Test("1280×480: 1× scale, symmetric horizontal letterbox")
    func wideHorizLetterbox() {
        // k=1: gw=640, ox=320
        let r = EngineRenderer.gameRect(for: CGSize(width: 1280, height: 480))
        #expect(r.x ≈ -0.5, "left = -0.5")
        #expect(r.z ≈  0.5, "right = +0.5")
        #expect(r.y ≈  1.0, "no vertical margin")
        #expect(r.w ≈ -1.0, "no vertical margin")
    }

    @Test("Horizontal letterbox: left margin = −right margin (symmetric)")
    func horizSymmetry() {
        let r = EngineRenderer.gameRect(for: CGSize(width: 1280, height: 480))
        #expect(r.x ≈ -r.z, "left = −right")
    }

    // MARK: Vertical letterbox (tall display, width limits scale)

    @Test("640×800: 1× scale, symmetric vertical letterbox")
    func tallVertLetterbox() {
        // k=1: gh=480, oy=(800-480)/2=160
        let r = EngineRenderer.gameRect(for: CGSize(width: 640, height: 800))
        let expTop    = Float(1.0 - 160.0 / 800.0 * 2.0)   // 1 - 0.4 = 0.6
        let expBottom = Float(1.0 - 640.0 / 800.0 * 2.0)   // 1 - 1.6 = -0.6
        #expect(r.x ≈ -1.0, "no horizontal margin")
        #expect(r.z ≈  1.0, "no horizontal margin")
        #expect(r.y ≈ expTop,    "top ≈ 0.6")
        #expect(r.w ≈ expBottom, "bottom ≈ -0.6")
    }

    @Test("Vertical letterbox: top margin = −bottom margin (symmetric)")
    func vertSymmetry() {
        let r = EngineRenderer.gameRect(for: CGSize(width: 640, height: 800))
        #expect(r.y ≈ -r.w, "top = −bottom")
    }

    // MARK: Invariants

    @Test("gameRect always satisfies left < right and bottom < top")
    func orderInvariant() {
        let sizes: [CGSize] = [
            CGSize(width: 640, height: 480),
            CGSize(width: 1920, height: 1080),
            CGSize(width: 1280, height: 480),
            CGSize(width: 640, height: 800),
            CGSize(width: 100, height: 100),    // smaller than native; k clamped to 1
            CGSize(width: 3840, height: 2160),  // 4K
        ]
        for size in sizes {
            let r = EngineRenderer.gameRect(for: size)
            #expect(r.x < r.z, "\(size): left must be < right")
            #expect(r.w < r.y, "\(size): bottom must be < top")
        }
    }

    @Test("gameRect corners are within [-1, 1] for reasonable display sizes")
    func boundsWithinNDC() {
        let sizes: [CGSize] = [
            CGSize(width: 640, height: 480),
            CGSize(width: 2560, height: 1440),
            CGSize(width: 5120, height: 2880),
        ]
        for size in sizes {
            let r = EngineRenderer.gameRect(for: size)
            #expect(r.x >= -1.0, "\(size): left out of NDC")
            #expect(r.z <= 1.0,  "\(size): right out of NDC")
            #expect(r.w >= -1.0, "\(size): bottom out of NDC")
            #expect(r.y <= 1.0,  "\(size): top out of NDC")
        }
    }
}

// MARK: - GPU-dependent tests

@Suite("EngineRenderer (GPU)")
struct EngineRendererGPUTests {

    private func device() -> MTLDevice? { MTLCreateSystemDefaultDevice() }

    @Test("EngineRenderer initialises on default Metal device")
    func rendererInit() throws {
        guard let dev = device() else { return }
        let _ = try EngineRenderer(device: dev)
        #expect(true)
    }

    @Test("update(framebuffer:palette:) uploads without crashing")
    func updateNoCrash() throws {
        guard let dev = device() else { return }
        let renderer = try EngineRenderer(device: dev)

        // Ramp through palette indices 0–15
        var fb = Framebuffer()
        for i in fb.pixels.indices { fb.pixels[i] = UInt8(i % 16) }

        // Synthesise a 16-entry grey-ramp palette using the new direct init
        let palette = EnginePalette(colors: (0..<16).map { i in
            let v = UInt8(i * 17)   // 0, 17, 34, … 255
            return EnginePalette.RGBA(r: v, g: v, b: v)
        })

        renderer.update(framebuffer: fb, palette: palette)
        #expect(true)
    }

    @Test("update with all-transparent framebuffer (sentinel 0xFF) does not crash")
    func updateSentinel() throws {
        guard let dev = device() else { return }
        let renderer = try EngineRenderer(device: dev)

        var fb = Framebuffer()
        for i in fb.pixels.indices { fb.pixels[i] = 0xFF }   // all sentinel

        renderer.update(framebuffer: fb, palette: .black)
        #expect(true)
    }

    @Test("render(to:drawableSize:) encodes command buffer without crashing")
    func renderNoCrash() throws {
        guard let dev = device() else { return }
        let renderer = try EngineRenderer(device: dev)

        // Off-screen CAMetalLayer for a test drawable
        let layer = CAMetalLayer()
        layer.device          = dev
        layer.pixelFormat     = .bgra8Unorm
        layer.drawableSize    = CGSize(width: 640, height: 480)
        layer.framebufferOnly = false   // allow off-screen use in tests

        renderer.update(framebuffer: Framebuffer(), palette: .black)

        // nextDrawable may be nil without a run loop; the test just checks
        // that we handle both outcomes gracefully.
        if let drawable = layer.nextDrawable() {
            renderer.render(to: drawable, drawableSize: layer.drawableSize)
        }
        #expect(true)
    }

    @Test("Multiple successive renders do not crash")
    func multipleRenders() throws {
        guard let dev = device() else { return }
        let renderer = try EngineRenderer(device: dev)

        let layer = CAMetalLayer()
        layer.device          = dev
        layer.pixelFormat     = .bgra8Unorm
        layer.drawableSize    = CGSize(width: 640, height: 480)
        layer.framebufferOnly = false

        let palette = EnginePalette.black
        for i in 0 ..< 5 {
            var fb = Framebuffer()
            // Different content each time to exercise the upload path
            for j in fb.pixels.indices { fb.pixels[j] = UInt8((i + j) % 16) }
            renderer.update(framebuffer: fb, palette: palette)
            if let drawable = layer.nextDrawable() {
                renderer.render(to: drawable, drawableSize: layer.drawableSize)
            }
        }
        #expect(true)
    }

    @Test("Renderer handles letterboxed 1920×1080 drawable without crash")
    func renderLetterboxed() throws {
        guard let dev = device() else { return }
        let renderer = try EngineRenderer(device: dev)

        let layer = CAMetalLayer()
        layer.device          = dev
        layer.pixelFormat     = .bgra8Unorm
        layer.drawableSize    = CGSize(width: 1920, height: 1080)
        layer.framebufferOnly = false

        renderer.update(framebuffer: Framebuffer(), palette: .black)
        if let drawable = layer.nextDrawable() {
            renderer.render(to: drawable, drawableSize: layer.drawableSize)
        }
        #expect(true)
    }
}
