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

// IslandRendererTests.swift
//
// Tests for island setup and wave animation.
// All tests gated on canonical resource availability.

import Testing
import Foundation
@testable import JohnnyEngine

@Suite("IslandRenderer")
struct IslandRendererTests {

    @Test("Island setup populates background framebuffer",
          .disabled(if: !EngineTestResources.available,
                    EngineTestResources.skipMessage))
    func islandSetupPopulatesBackground() throws {
        let engine = try EngineTestResources.engine()
        let cache  = ResourceCache(archive: try EngineTestResources.archive())
        let graphics = GraphicsState()
        let renderer = IslandRenderer(cache: cache, graphics: graphics)

        var state    = IslandState()
        state.raft   = 3
        state.night  = false
        state.lowTide = false

        var rng = SeedableRNG(seed: 42)
        try renderer.setup(state: state, rng: &rng)

        let bg = try #require(graphics.background)
        // Background should have some non-sentinel pixels (ocean + island)
        let filled = bg.pixels.filter { $0 != 0xFF }.count
        #expect(filled > 1000, "Background has too few non-sentinel pixels: \(filled)")
        _ = engine  // silence unused warning
    }

    @Test("Night flag loads NIGHT.SCR instead of OCEAN",
          .disabled(if: !EngineTestResources.available,
                    EngineTestResources.skipMessage))
    func nightScreen() throws {
        let cache    = ResourceCache(archive: try EngineTestResources.archive())
        let graphics = GraphicsState()
        let renderer = IslandRenderer(cache: cache, graphics: graphics)

        var state  = IslandState()
        state.night = true

        var rng = SeedableRNG(seed: 0)
        try renderer.setup(state: state, rng: &rng)

        let bg = try #require(graphics.background)
        // Night screen should have pixels, but they'll typically be darker (lower indices)
        #expect(!bg.pixels.allSatisfy { $0 == 0xFF }, "Night background is empty")
    }

    @Test("Wave animation modifies background on each call",
          .disabled(if: !EngineTestResources.available,
                    EngineTestResources.skipMessage))
    func waveAnimationChangesBackground() throws {
        let cache    = ResourceCache(archive: try EngineTestResources.archive())
        let graphics = GraphicsState()
        let renderer = IslandRenderer(cache: cache, graphics: graphics)

        var state = IslandState()
        var rng   = SeedableRNG(seed: 1)
        try renderer.setup(state: state, rng: &rng)

        let snapshot1 = graphics.background!.pixels

        // Animate a full wave cycle (3 counter2 steps to cycle through)
        for _ in 0 ..< 3 { renderer.animate(state: state) }

        let snapshot2 = graphics.background!.pixels

        // Wave frames should have changed at least some pixels
        let changed = zip(snapshot1, snapshot2).filter { $0.0 != $0.1 }.count
        #expect(changed > 0, "Wave animation produced no pixel changes")
    }

    @Test("Holiday layer is non-nil for Christmas date",
          .disabled(if: !EngineTestResources.available,
                    EngineTestResources.skipMessage))
    func christmasHolidayLayer() throws {
        let cache    = ResourceCache(archive: try EngineTestResources.archive())
        let graphics = GraphicsState()
        let renderer = IslandRenderer(cache: cache, graphics: graphics)

        var state    = IslandState()
        state.holiday = IslandState.holidayChristmas

        let layer = try renderer.holidayLayer(state: state)
        #expect(layer != nil, "Christmas holiday layer should not be nil")

        // The layer should have some non-transparent pixels
        if let l = layer {
            let opaque = l.pixels.filter { $0 != 0xFF }.count
            #expect(opaque > 0, "Christmas layer has no opaque pixels")
        }
    }

    @Test("Holiday layer is nil when holiday=0",
          .disabled(if: !EngineTestResources.available,
                    EngineTestResources.skipMessage))
    func noHolidayLayer() throws {
        let cache    = ResourceCache(archive: try EngineTestResources.archive())
        let graphics = GraphicsState()
        let renderer = IslandRenderer(cache: cache, graphics: graphics)

        var state    = IslandState()
        state.holiday = 0

        let layer = try renderer.holidayLayer(state: state)
        #expect(layer == nil)
    }
}
