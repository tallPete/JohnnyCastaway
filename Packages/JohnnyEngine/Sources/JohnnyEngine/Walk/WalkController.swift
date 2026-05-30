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

// WalkController.swift
//
// Johnny's island-walk animation state machine.
// Translated from jc_reborn's walk.c (walkInit / walkAnimate).
//
// Usage:
//   var w = WalkController(from: Spot.A, fromHdg: Heading.SW,
//                          to: Spot.C, toHdg: Heading.SE,
//                          path: calcPath(from: 0, to: 2, rng: &rng))
//   while !w.isDone {
//       let delay = w.animate(onto: &layer, johnWalkBmp: bmp,
//                             bgBmp: backgrndBmp, graphics: g)
//       // render frame; sleep delay ticks
//   }
//
// See walk.c:47–180 for the reference implementation.
//
// Key behaviour notes:
//   • delay == 6  — walking frame; continue calling animate()
//   • delay == 80 — arrived; one hold frame, then next call returns 0
//   • delay == 0  — done; stop calling animate()
//   • "behind tree" condition (D↔E) overlays trunk+leaves from BACKGRND.BMP

import Foundation
import JohnnyResources

// MARK: - WalkController

public class WalkController {

    // ---------------------------------------------------------------
    // MARK: Private state (mirrors walk.c file-level statics)
    // ---------------------------------------------------------------

    private var walkPath:     [Int]   // remaining intermediate + final spots
    private var pathIndex:    Int     // next entry to consume from walkPath

    private var currentSpot:  Int
    private var currentHdg:   Int
    private var nextSpot:     Int     // -1 = turning towards finalHdg
    private var nextHdg:      Int     // -1 = we're walking forward
    private var finalSpot:    Int
    private var finalHdg:     Int
    private var increment:    Int     // +1 CW, -1 CCW, 0 no turn needed
    private var lastTurn:     Bool
    private var hasArrived:   Bool
    private var isBehindTree: Bool

    private var dataIndex:    Int     // current position in walkDataFlat (frame index)

    // ---------------------------------------------------------------
    // MARK: Init (walk.c:47–71)
    // ---------------------------------------------------------------

    /// Initialise a walk between two spots.
    /// - Parameters:
    ///   - path: Array returned by `calcPath(from:to:rng:)` — intermediate
    ///           spots plus the destination, in order. Pass `[]` for same-spot.
    public init(
        from:    Int,
        fromHdg: Int,
        to:      Int,
        toHdg:   Int,
        path:    [Int]
    ) {
        walkPath     = path
        pathIndex    = 0

        currentSpot  = from
        currentHdg   = fromHdg
        finalSpot    = to
        finalHdg     = toHdg
        hasArrived   = false
        isBehindTree = false
        nextSpot     = -1
        nextHdg      = -1
        increment    = 0
        lastTurn     = false
        dataIndex    = 0

        if from == to {
            // Already at destination — just turn to face final heading
            nextSpot = -1
            nextHdg  = finalHdg
            lastTurn = true
        } else {
            // First intermediate spot
            nextSpot = walkPath[pathIndex]
            pathIndex += 1
            nextHdg  = walkDataStartHeadings[currentSpot][nextSpot]
            lastTurn = false
        }

        increment = turnIncrement(from: currentHdg, to: nextHdg)
        // Point dataIndex to the first turn frame at currentSpot + currentHdg
        dataIndex = walkDataBookmarksTurns[currentSpot] + currentHdg
    }

    // ---------------------------------------------------------------
    // MARK: Public interface
    // ---------------------------------------------------------------

    /// True when the walk is fully finished (delay 0 was returned).
    public var isDone: Bool { hasArrived && delay(for: dataIndex) == 0 }

    /// Advance one animation frame. Draws the appropriate sprite(s).
    /// Returns the delay for this frame (6 = walking, 80 = arrived/hold, 0 = done).
    ///
    /// - Parameters:
    ///   - layer:      TTM layer to draw onto (cleared and redrawn each frame).
    ///   - walkBmp:    JOHNWALK.BMP sprite sheet.
    ///   - bgBmp:      BACKGRND.BMP (for behind-tree overlay).
    ///   - graphics:   Current GraphicsState (provides dx/dy offsets).
    @discardableResult
    public func animate(
        onto  layer:   inout Framebuffer,
        walkBmp:       Bitmap,
        bgBmp:         Bitmap,
        graphics:      GraphicsState
    ) -> Int {

        if hasArrived {
            // The previous call returned 80 (one hold frame). Now we're truly done.
            return 0
        }

        // -------------------------------------------------------
        // Advance walk state machine (walk.c:81–173)
        // -------------------------------------------------------

        if nextHdg != -1 {
            // Turning phase
            let delta = (nextHdg - currentHdg) & 0x07
            if delta > 1 && delta < 7 {
                // More than one turn step remaining — rotate one heading
                currentHdg = (currentHdg + increment) & 7
                dataIndex  = walkDataBookmarksTurns[currentSpot] + currentHdg
                if lastTurn { dataIndex += 9 }   // hands-in-pockets
            } else {
                // Turn is complete
                if currentSpot != finalSpot {
                    // Begin walking forward to nextSpot
                    let wasBehind = isBehindTree
                    isBehindTree = (currentSpot == Spot.D && nextSpot == Spot.E)
                               || (currentSpot == Spot.E && nextSpot == Spot.D)
                    if isBehindTree && !wasBehind {
                        print("[walk] isBehindTree SET: currentSpot=\(currentSpot) nextSpot=\(nextSpot)")
                    } else if !isBehindTree && wasBehind {
                        print("[walk] isBehindTree CLEARED: currentSpot=\(currentSpot) nextSpot=\(nextSpot)")
                    }
                    nextHdg  = -1
                    dataIndex = walkDataBookmarks[currentSpot][nextSpot]
                } else {
                    // Arrived — switch to hands-in-pockets idle at finalSpot
                    dataIndex  = walkDataBookmarksTurns[finalSpot] + finalHdg + 9
                    hasArrived = true
                }
            }
        } else {
            // Walking forward
            dataIndex += 1

            // Sentinel check: rawX == 0 means we've reached the next spot
            if isWalkEndMarker(at: dataIndex) {
                currentHdg  = walkDataEndHeadings[currentSpot][nextSpot]
                currentSpot = nextSpot

                if currentSpot != finalSpot {
                    nextSpot = walkPath[pathIndex]
                    pathIndex += 1
                    nextHdg = walkDataStartHeadings[currentSpot][nextSpot]
                } else {
                    nextHdg  = finalHdg
                    lastTurn = true
                }

                increment  = turnIncrement(from: currentHdg, to: nextHdg)
                currentHdg = (currentHdg + increment) & 7
                dataIndex  = walkDataBookmarksTurns[currentSpot] + currentHdg

                if lastTurn {
                    dataIndex += 9   // hands-in-pockets
                    if currentHdg == finalHdg {
                        hasArrived = true
                    }
                }
            }
        }

        // -------------------------------------------------------
        // Draw the current frame (walk.c:155–172)
        // -------------------------------------------------------

        graphics.clearScreen(layer: &layer)

        let frame = walkFrame(at: dataIndex)
        if frame.rawX != 0 {
            let x = Int(frame.rawX) - 1
            let y = Int(frame.y)
            let s = Int(frame.sprite)
            if frame.flip != 0 {
                graphics.drawSpriteFlip(on: &layer, bitmap: walkBmp, x: x, y: y,
                                        spriteNo: s, imageNo: 0)
            } else {
                graphics.drawSprite(on: &layer, bitmap: walkBmp, x: x, y: y,
                                    spriteNo: s, imageNo: 0)
            }
        }

        // Behind-tree overlay (D↔E path).
        // Draw trunk and leaves from BACKGRND.BMP onto the walk layer AFTER
        // Johnny — same as jc_reborn walk.c:164–167. This makes trunk/leaves
        // appear in front of Johnny on the walk layer, which is composited on
        // top of the background (which already contains trunk+leaves baked in).
        // Net result: palm tree appears in front of Johnny. ✓
        // Coordinates match jc_reborn walk.c:165-166 exactly.
        if isBehindTree {
            graphics.drawSprite(on: &layer, bitmap: bgBmp, x: 442, y: 148, spriteNo: 13, imageNo: 0)  // trunk
            graphics.drawSprite(on: &layer, bitmap: bgBmp, x: 365, y: 122, spriteNo: 12, imageNo: 0)  // leafs
        }

        return hasArrived ? 80 : 6
    }

    // ---------------------------------------------------------------
    // MARK: Private helpers
    // ---------------------------------------------------------------

    /// Compute turning increment: +1 (CW), -1 (CCW), or 0 (no turn needed).
    /// Mirrors walk.c:69–70 and walk.c:136–138.
    private func turnIncrement(from: Int, to: Int) -> Int {
        guard to != -1 else { return 0 }
        let delta = (to - from) & 0x07
        if delta == 0 { return 0 }
        return delta < 4 ? 1 : -1
    }

    private func delay(for _: Int) -> Int { hasArrived ? 80 : 6 }
}
