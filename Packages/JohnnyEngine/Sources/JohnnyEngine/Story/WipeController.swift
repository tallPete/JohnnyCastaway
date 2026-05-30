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

// WipeController.swift
//
// Screen wipe (fade-out transition) animation. Translation of grFadeOut()
// in jc_reborn's graphics.c:604–668.
//
// Five transition types are available. The caller is responsible for
// selecting which type to use — StoryRunner holds the per-instance cycle
// counter so that multiple screensaver view instances (e.g. multi-display
// or System Settings preview pane) each cycle independently:
//
//   Type 0 — Circle iris from centre  (20 frames, radius 20→400 step 20)
//   Type 1 — Rectangle iris from centre (20 frames, i=1→20)
//   Type 2 — Bars sweep right to left  (16 frames, x=600→0 step 40)
//   Type 3 — Bars sweep left to right  (16 frames, x=0→600 step 40)
//   Type 4 — Bars split from centre   (16 frames, i=0→300 step 20)
//
// The black colour index (5) matches jc_reborn's `fgColor=5, bgColor=5`
// arguments and the SDL colour-key / VGA palette where index 5 is black.

import Foundation

struct WipeController {

    private let type: Int
    private var step: Int = 0
    private let totalSteps: Int

    // Framebuffer being painted. Starts as a snapshot of the last scene;
    // each advanceFrame() call draws one step of the wipe into it.
    private(set) var frame: Framebuffer

    static let typeCount = 5
    private static let stepCounts = [20, 20, 16, 16, 16]

    /// - Parameter type: Wipe type 0–4. Caller manages cycling.
    init(snapshot: Framebuffer, type: Int) {
        self.frame      = snapshot
        self.type       = type % WipeController.typeCount
        self.totalSteps = WipeController.stepCounts[self.type]
    }

    var isFinished: Bool { step >= totalSteps }

    /// Draw the next wipe step onto `frame` and advance the step counter.
    /// Returns `true` while the wipe is still in progress, `false` when done.
    @discardableResult
    mutating func advanceFrame() -> Bool {
        guard !isFinished else { return false }
        applyStep(step)
        step += 1
        return !isFinished
    }

    // MARK: - Step rendering

    private mutating func applyStep(_ step: Int) {
        let black: UInt8 = 5   // palette index 5 = black (jc_reborn colour key)
        switch type {

        case 0:
            // Circle iris — radius 20, 40, …, 400. Matches graphics.c:619–625:
            //   grDrawCircle(tmpSfc, 320-radius, 240-radius, radius*2, radius*2, 5, 5)
            let r = (step + 1) * 20
            fillDisc(x1: 320 - r, y1: 240 - r, diameter: r * 2, color: black)

        case 1:
            // Rectangle iris — i=1..20. Matches graphics.c:631–635:
            //   grDrawRect(sfc, 320-i*16, 240-i*12, i*32, i*24, 5)
            let i = step + 1
            fillRect(x: 320 - i * 16, y: 240 - i * 12,
                     w: i * 32,       h: i * 24, color: black)

        case 2:
            // Bars right→left. Matches graphics.c:639–643:
            //   for i=600; i>=0; i-=40 { grDrawRect(sfc, i, 0, 40, 480, 5) }
            fillRect(x: 600 - step * 40, y: 0, w: 40, h: Framebuffer.height, color: black)

        case 3:
            // Bars left→right. Matches graphics.c:647–651:
            //   for i=0; i<640; i+=40 { grDrawRect(sfc, i, 0, 40, 480, 5) }
            fillRect(x: step * 40, y: 0, w: 40, h: Framebuffer.height, color: black)

        case 4:
            // Bars split from centre. Matches graphics.c:655–661:
            //   for i=0; i<320; i+=20 { grDrawRect 320+i and 300-i }
            let i = step * 20
            fillRect(x: 320 + i, y: 0, w: 20, h: Framebuffer.height, color: black)
            fillRect(x: 300 - i, y: 0, w: 20, h: Framebuffer.height, color: black)

        default:
            break
        }
    }

    // MARK: - Direct framebuffer helpers (screen space, no dx/dy offset)

    /// Fill a solid disc. Arguments mirror grDrawCircle() in graphics.c:369–453
    /// with fgColor==bgColor (solid fill, no outline pass) and dx=dy=0.
    private mutating func fillDisc(x1 inX1: Int, y1 inY1: Int, diameter: Int, color: UInt8) {
        guard diameter > 0 && diameter % 2 == 0 else { return }
        let r  = (diameter >> 1) - 1
        let xc = inX1 + r
        let yc = inY1 + r
        var px = 0, py = r
        var d  = 1 - r
        while true {
            hLine(x1: xc - px, x2: xc + px + 1, y: yc + py + 1, color: color)
            hLine(x1: xc - px, x2: xc + px + 1, y: yc - py,     color: color)
            hLine(x1: xc - py, x2: xc + py + 1, y: yc + px + 1, color: color)
            hLine(x1: xc - py, x2: xc + py + 1, y: yc - px,     color: color)
            if py - px <= 1 { break }
            if d < 0 {
                d += (px << 1) + 3
            } else {
                d += ((px - py) << 1) + 5
                py -= 1
            }
            px += 1
        }
    }

    /// Fill a rectangle. Arguments mirror grDrawRect() in graphics.c:353–366
    /// with dx=dy=0.
    private mutating func fillRect(x inX: Int, y inY: Int, w: Int, h: Int, color: UInt8) {
        let x1 = max(inX, 0)
        let y1 = max(inY, 0)
        let x2 = min(inX + w, Framebuffer.width)
        let y2 = min(inY + h, Framebuffer.height)
        guard x1 < x2, y1 < y2 else { return }
        for row in y1 ..< y2 {
            let base = row * Framebuffer.width
            for col in x1 ..< x2 {
                frame.pixels[base + col] = color
            }
        }
    }

    private mutating func hLine(x1: Int, x2: Int, y: Int, color: UInt8) {
        guard y >= 0 && y < Framebuffer.height else { return }
        let cx1 = max(x1, 0)
        let cx2 = min(x2, Framebuffer.width)
        guard cx1 < cx2 else { return }
        let base = y * Framebuffer.width
        for x in cx1 ..< cx2 {
            frame.pixels[base + x] = color
        }
    }
}
