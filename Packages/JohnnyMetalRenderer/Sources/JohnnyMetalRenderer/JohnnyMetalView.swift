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

// JohnnyMetalView.swift
//
// An AppKit NSView backed by a CAMetalLayer, driving a JohnnyEngine at the
// game's native tick rate while presenting frames at the display's native
// refresh rate (CADisplayLink, macOS 14+).
//
// Design:
//   • makeBackingLayer() returns a CAMetalLayer so the view's compositing
//     tree renders via Metal rather than Core Animation software rasterisation.
//   • A CADisplayLink fires renderFrame() on the main thread at the display's
//     native Hz (typically 60 or 120 Hz on Apple Silicon).
//   • Engine ticks are decoupled from display refresh: renderFrame() only
//     calls engine.tick() when at least `lastMini` milliseconds have elapsed
//     since the previous tick. Between ticks the most-recently-uploaded
//     framebuffer is re-presented unchanged.
//   • startRendering() / stopRendering() are called from viewDidMoveToWindow
//     so the display link is active only while the view is on screen.
//
// Usage (Phase 5 debug app):
//   let view  = JohnnyMetalView(frame: NSRect(…))
//   let engine = try Engine(archive: archive)
//   try engine.beginADS(name: "JOHNNY.ADS", tag: 1)
//   view.engine = engine
//   hostWindow.contentView = view
//
// For the .saver (Phase 6): ScreenSaverView cannot subclass NSView directly,
// so that target uses EngineRenderer directly with its own display link.

import AppKit
import Metal
import QuartzCore
import JohnnyEngine

// MARK: - JohnnyMetalView

/// NSView subclass that hosts a JohnnyEngine and renders via Metal.
///
/// All public properties and methods must be accessed from the main thread.
@MainActor
public final class JohnnyMetalView: NSView {

    // ---------------------------------------------------------------
    // MARK: Public
    // ---------------------------------------------------------------

    /// The engine to render in simple-ADS mode.
    /// Takes effect only when `frameProvider` is nil.
    public var engine: Engine?

    /// An optional higher-level frame provider that replaces the simple
    /// `engine` path. When set, the view calls this closure each display
    /// tick (subject to the same `lastMini` pacing as the engine path)
    /// and expects either:
    ///   - `(Framebuffer, EnginePalette, Int)` — a new frame to upload
    ///     (Int = mini ticks, sets the pacing interval); or
    ///   - `nil` — no new frame; the last-rendered frame is repeated.
    ///
    /// Set by the debug app to delegate ticking to `EngineDebugState`
    /// (which handles pause/step/scene-override logic). The .saver target
    /// (Phase 6) will use `EngineRenderer` directly instead of this view.
    public var frameProvider: (@MainActor () -> (Framebuffer, EnginePalette, Int)?)?

    // ---------------------------------------------------------------
    // MARK: Private — Metal state
    // ---------------------------------------------------------------

    private var metalLayer:   CAMetalLayer!
    private var renderer:     EngineRenderer?
    private var activeDisplayLink:  CADisplayLink?

    // Engine tick pacing: wait at least `lastMini` ms between ticks.
    // Initialised to 4 (the SET_DELAY minimum clamp from ttm.c).
    private var lastMini: Int = 4
    private var lastTickTime: CFTimeInterval = 0

    // ---------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------

    public override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
    }

    // ---------------------------------------------------------------
    // MARK: Layer setup
    // ---------------------------------------------------------------

    /// Called by AppKit once, before viewDidMoveToWindow. Returns the
    /// CAMetalLayer that backs this view.
    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat       = .bgra8Unorm
        layer.framebufferOnly   = true          // no CPU readback needed
        layer.backgroundColor   = CGColor.black
        layer.displaySyncEnabled = true          // lock presentation to VBL
        metalLayer = layer
        return layer
    }

    // ---------------------------------------------------------------
    // MARK: Window lifecycle
    // ---------------------------------------------------------------

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startRendering()
        } else {
            stopRendering()
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Keep drawable size in sync with the backing-store size (HiDPI aware).
        metalLayer?.drawableSize = convertToBacking(bounds.size)
    }

    // ---------------------------------------------------------------
    // MARK: Start / stop
    // ---------------------------------------------------------------

    private func startRendering() {
        guard renderer == nil else { return }   // already running
        guard let device = MTLCreateSystemDefaultDevice() else {
            // No GPU available (unlikely on a real Mac, but handle gracefully)
            return
        }

        metalLayer.device      = device
        metalLayer.drawableSize = convertToBacking(bounds.size)

        do {
            renderer = try EngineRenderer(device: device)
        } catch {
            // Renderer setup failure is non-fatal: the view just stays black.
            return
        }

        lastTickTime = CACurrentMediaTime()

        // On macOS 14+, CADisplayLink must be created from an NSView/NSWindow/NSScreen
        // (the class-level CADisplayLink(target:selector:) initialiser is unavailable on macOS).
        // NSView.displayLink(withTarget:selector:) ties the link to the view's screen.
        let link = self.displayLink(target: self, selector: #selector(renderFrame))
        link.add(to: .main, forMode: .common)
        activeDisplayLink = link
    }

    private func stopRendering() {
        activeDisplayLink?.invalidate()
        activeDisplayLink = nil
        renderer    = nil
    }

    // ---------------------------------------------------------------
    // MARK: Frame callback
    // ---------------------------------------------------------------

    /// Called by CADisplayLink on the main thread at the display's native Hz.
    @objc private func renderFrame() {
        guard let renderer else { return }

        let now       = CACurrentMediaTime()
        let elapsedMS = (now - lastTickTime) * 1000.0

        if elapsedMS >= Double(lastMini) {
            if let provider = frameProvider {
                // Higher-level provider (e.g. EngineDebugState): returns a new
                // frame + pacing hint, or nil when paused/no change.
                if let (fb, pal, mini) = provider() {
                    // jc_reborn events.c:108 — sleep duration in ms is mini*20
                    // (1 mini-tick ≈ 20ms wall clock). Floor at 4ms so we never
                    // spin at display Hz when mini=0 (idle/transition states).
                    lastMini     = max(4, mini * 20)
                    lastTickTime = now
                    renderer.update(framebuffer: fb, palette: pal)
                }
            } else if let engine {
                // Simple Engine path: always tick when the pacing interval elapses.
                lastMini     = max(4, engine.tick() * 20)
                lastTickTime = now
                renderer.update(framebuffer: engine.composedFramebuffer,
                                palette:    engine.palette)
            }
        }

        // Always render at display refresh rate (repeats last frame between ticks).
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer.render(to: drawable, drawableSize: metalLayer.drawableSize)
    }

    // ---------------------------------------------------------------
    // MARK: Dealloc / cleanup
    // ---------------------------------------------------------------

    deinit {
        // activeDisplayLink.invalidate() must be called from the main thread;
        // we can't call it here because deinit has no actor context.
        // stopRendering() is called from viewDidMoveToWindow(nil) before
        // deallocation, so the display link is already invalid by now.
    }
}
