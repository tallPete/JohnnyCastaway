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

// IslandRenderer.swift
//
// Island background setup and wave animation.
// Translated from jc_reborn's island.c + Go-port fixes (island.go).
//
// Responsibilities:
//   • setup()        — islandInit() in C: loads ocean/night SCR, draws raft,
//                      clouds, island sprites, and does 4 initial wave ticks.
//   • animate()      — islandAnimate() in C: advances the wave counter and
//                      blits the next wave frame onto the background.
//   • setupHoliday() — islandInitHoliday() in C: draws the season decoration
//                      (Halloween/St Patrick/Christmas/New Year) onto a
//                      separate transparent layer.
//
// Go-port fix (island.go:194):  counter1 %= 2  (jc_reborn uses %= 3)
// This matches the visible 2-frame wave cycle in the original Windows version.
//
// Reference: jc_reborn island.c:35–218; Go port island.go

import Foundation
import JohnnyResources

// MARK: - IslandRenderer

/// Drives the island background: ocean/night screen, waves, clouds, raft,
/// and seasonal holiday decorations.
public final class IslandRenderer {

    // ---------------------------------------------------------------
    // MARK: Dependencies
    // ---------------------------------------------------------------

    private let cache:    ResourceCache
    private let graphics: GraphicsState

    // ---------------------------------------------------------------
    // MARK: Fidelity mode
    // ---------------------------------------------------------------

    /// Controls wave-counter modulo (and any future island-layer divergences).
    /// Set by StoryRunner when the debug overlay changes the fidelity toggle.
    public var fidelityMode: FidelityMode = .fixed

    // ---------------------------------------------------------------
    // MARK: Wave animation counters (static in C; instance vars here)
    // ---------------------------------------------------------------

    private var counter1: Int = 0   // wave frame index (0–1 fixed, 0–2 raw)
    private var counter2: Int = 0   // which shore position to update

    // ---------------------------------------------------------------
    // MARK: Slot holding BACKGRND.BMP during animation
    // ---------------------------------------------------------------

    /// The TTMSlot used by the background/island thread.
    /// Loaded once during setup(); reused for each animate() call.
    let backgroundSlot: TTMSlot

    // ---------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------

    public init(cache: ResourceCache, graphics: GraphicsState) {
        self.cache       = cache
        self.graphics    = graphics
        self.backgroundSlot = TTMSlot()
    }

    // ---------------------------------------------------------------
    // MARK: Island setup (island.c:35–147)
    // ---------------------------------------------------------------

    /// Draw the full island background (ocean/night, raft, clouds, island
    /// base sprites, and 4 initial wave ticks) into `graphics.background`.
    ///
    /// After this call `graphics.background` is the composited base layer.
    /// Mirrors `islandInit()` in island.c, with Go cloud distribution.
    ///
    /// - Parameters:
    ///   - state:   IslandState computed by SceneScheduler.
    ///   - rng:     Randomness source for cloud placement.
    public func setup(state: IslandState, rng: inout some RandomNumberGenerator) throws {
        // Reset wave counters for new scene
        counter1 = 0
        counter2 = 0

        // Set island position offsets on the graphics state
        graphics.dx = state.xPos
        graphics.dy = state.yPos

        // ---- Ocean / night screen ----
        let scrName = state.night ? "NIGHT.SCR" : "OCEAN0\(Int.random(in: 0..<3, using: &rng)).SCR"
        let scr = try cache.screen(named: scrName)
        graphics.loadScreen(scr)

        // ---- Raft ---- (island.c:56–68)
        backgroundSlot.reset()
        let raftBmp = try cache.bitmap(named: "MRAFT.BMP")
        backgroundSlot.bitmaps[0] = raftBmp

        if state.raft >= 1 {
            let xRaft = state.lowTide ? 529 : 512
            let yRaft = state.lowTide ? 281 : 266
            guard var bg = graphics.background else { return }
            graphics.drawSprite(on: &bg, bitmap: raftBmp,
                                x: xRaft, y: yRaft,
                                spriteNo: state.raft - 1, imageNo: 0)
            graphics.background = bg
        }

        // ---- Clouds ---- (island.c:74–121; Go cloud distribution)
        let backgrndBmp = try cache.bitmap(named: "BACKGRND.BMP")
        backgroundSlot.bitmaps[0] = backgrndBmp

        let savedDx = graphics.dx
        let savedDy = graphics.dy
        graphics.dx = 0
        graphics.dy = 0

        // Go port uses uniform 0–5 clouds (island.go:101)
        let numClouds    = Int.random(in: 0...5, using: &rng)
        let windFromLeft = Bool.random(using: &rng)

        for _ in 0 ..< numClouds {
            let cloudNo = Int.random(in: 0..<3, using: &rng)
            let cx: Int
            let cy: Int
            switch cloudNo {
            case 0:
                cx = Int.random(in: 0..<(640 - 129), using: &rng)
                cy = Int.random(in: 0..<(135 - 36),  using: &rng)  // rand() % 99  → [0, 98]
            case 1:
                cx = Int.random(in: 0..<(640 - 192), using: &rng)
                cy = Int.random(in: 0..<(135 - 57),  using: &rng)  // rand() % 78  → [0, 77]
            default:  // 2
                cx = Int.random(in: 0..<(640 - 264), using: &rng)
                cy = Int.random(in: 0..<(135 - 76),  using: &rng)  // rand() % 59  → [0, 58]
            }
            guard var bg = graphics.background else { break }
            if windFromLeft {
                graphics.drawSprite(on: &bg, bitmap: backgrndBmp,
                                    x: cx, y: cy,
                                    spriteNo: 15 + cloudNo, imageNo: 0)
            } else {
                graphics.drawSpriteFlip(on: &bg, bitmap: backgrndBmp,
                                        x: cx, y: cy,
                                        spriteNo: 15 + cloudNo, imageNo: 0)
            }
            graphics.background = bg
        }

        graphics.dx = savedDx
        graphics.dy = savedDy

        // ---- Island base sprites ---- (island.c:127–137)
        guard var bg = graphics.background else { return }
        graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 288, y: 279, spriteNo:  0, imageNo: 0)  // island
        graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 442, y: 148, spriteNo: 13, imageNo: 0)  // trunk
        graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 365, y: 122, spriteNo: 12, imageNo: 0)  // leafs
        graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 396, y: 279, spriteNo: 14, imageNo: 0)  // palmtree shadow
        if state.lowTide {
            graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 249, y: 303, spriteNo:  1, imageNo: 0)  // low tide shore
            graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 150, y: 328, spriteNo:  2, imageNo: 0)  // rock
        }
        graphics.background = bg

        // ---- Initial wave ticks (4 iterations, island.c:141–142) ----
        for _ in 0 ..< 4 {
            animate(state: state)
        }

        // Mark this as an island background so the wave-animation thread
        // is allowed to overlay wave sprites on it. A subsequent TTM
        // LOAD_SCREEN within a scene will flip this back to false (via
        // graphics.loadScreen), which suppresses the wave overlay so we
        // don't draw wave splashes at meaningless positions over a
        // close-up scene background like ISLAND2.SCR.
        graphics.isIslandBackground = true
    }

    // ---------------------------------------------------------------
    // MARK: Wave animation (island.c:150–188; Go fix counter1 %= 2)
    // ---------------------------------------------------------------

    /// Advance wave animation by one tick. Draws the next wave frame onto
    /// `graphics.background`. Called by the background thread on each timer
    /// firing (every 8 ticks).
    ///
    /// Go fix: `counter1 %= 2` (jc_reborn uses `%=3`).
    public func animate(state: IslandState) {
        // Skip wave overlay when the current background isn't the regular
        // ocean island (e.g. a scene's TTM ran LOAD_SCREEN ISLAND2.SCR).
        // Wave sprite positions are designed for the ocean-island layout;
        // drawing them over a close-up scene background produces stray
        // wave splashes at the wrong positions.
        guard graphics.isIslandBackground else { return }
        guard let backgrndBmp = backgroundSlot.bitmaps[0],
              var bg = graphics.background else { return }

        // Save/restore the global dx/dy. Without this, the wave thread's
        // tick clobbers the scene's offset that StoryRunner just set in
        // transitionToNextScene, so the next TTM tick draws sprites at the
        // wave-thread offset instead of the scene's own offset. Result:
        // sprites alternate between two positions every frame, producing
        // "multiple Johnnys" trails as the (uncleared) old layer state
        // accumulates. (Scenes that LOAD_SCREEN their own background are
        // especially affected because their dx is intentionally non-island.)
        let savedDx = graphics.dx
        let savedDy = graphics.dy
        defer {
            graphics.dx = savedDx
            graphics.dy = savedDy
        }

        graphics.dx = state.xPos
        graphics.dy = state.yPos

        if state.lowTide {
            counter2 = (counter2 + 1) % 4
            switch counter2 {
            case 0: graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 129, y: 340, spriteNo: 39 + counter1, imageNo: 0)  // rock waves
            case 1: graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 233, y: 323, spriteNo: 30 + counter1, imageNo: 0)  // low tide waves L
            case 2: graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 367, y: 356, spriteNo: 33 + counter1, imageNo: 0)  // low tide waves C
            case 3: graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 558, y: 323, spriteNo: 36 + counter1, imageNo: 0)  // low tide waves R
            default: break
            }
        } else {
            counter2 = (counter2 + 1) % 3
            switch counter2 {
            case 0: graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 270, y: 306, spriteNo:  3 + counter1, imageNo: 0)  // high tide waves L
            case 1: graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 364, y: 319, spriteNo:  6 + counter1, imageNo: 0)  // high tide waves C
            case 2: graphics.drawSprite(on: &bg, bitmap: backgrndBmp, x: 518, y: 303, spriteNo:  9 + counter1, imageNo: 0)  // high tide waves R
            default: break
            }
        }

        if counter2 == 0 {
            counter1 = (counter1 + 1) % (fidelityMode == .fixed ? 2 : 3)
        }

        graphics.background = bg
    }

    // ---------------------------------------------------------------
    // MARK: Holiday decoration (island.c:192–218)
    // ---------------------------------------------------------------

    /// Draw the seasonal holiday decoration onto a new transparent layer.
    /// Returns nil if no holiday decoration applies.
    ///
    /// - Parameters:
    ///   - state:    IslandState (holiday field determines which sprite).
    /// - Returns: A Framebuffer with the holiday sprite blitted, or nil.
    public func holidayLayer(state: IslandState) throws -> Framebuffer? {
        guard state.holiday != 0 else { return nil }

        let holidayBmp = try cache.bitmap(named: "HOLIDAY.BMP")

        var layer = GraphicsState.newLayer()
        graphics.dx = state.xPos
        graphics.dy = state.yPos

        switch state.holiday {
        case IslandState.holidayHalloween:
            graphics.drawSprite(on: &layer, bitmap: holidayBmp, x: 410, y: 298, spriteNo: 0, imageNo: 0)
        case IslandState.holidayStPatrick:
            graphics.drawSprite(on: &layer, bitmap: holidayBmp, x: 333, y: 286, spriteNo: 1, imageNo: 0)
        case IslandState.holidayChristmas:
            graphics.drawSprite(on: &layer, bitmap: holidayBmp, x: 404, y: 267, spriteNo: 2, imageNo: 0)
        case IslandState.holidayNewYear:
            graphics.drawSprite(on: &layer, bitmap: holidayBmp, x: 361, y: 155, spriteNo: 3, imageNo: 0)
        default:
            break
        }

        return layer
    }
}
