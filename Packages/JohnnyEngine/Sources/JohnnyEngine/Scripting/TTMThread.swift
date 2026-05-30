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

// TTMThread.swift
//
// One concurrently-executing TTM thread within an ADS run.
// Translates struct TTtmThread in ttm.h / ads.c.
//
// State machine for `isRunning`:
//   0 — free (not in use)
//   1 — running
//   2 — done (reached end of bytecode or PURGE with sceneTimer == 0)
//   3 — special value used by jc_reborn for the background thread;
//       we reuse it for the same purpose.

import Foundation

final class TTMThread {

    // ---------------------------------------------------------------
    // MARK: Identity
    // ---------------------------------------------------------------

    /// Running state. 0 = free, 1 = running, 2 = done, 3 = bg-special.
    var isRunning: Int = 0

    /// The TTM slot this thread is playing.
    var ttmSlot: TTMSlot?

    /// The (slot, tag) pair this thread was started with.
    var sceneSlot: UInt16 = 0
    var sceneTag:  UInt16 = 0

    // ---------------------------------------------------------------
    // MARK: Instruction pointer
    // ---------------------------------------------------------------

    /// Byte offset into ttmSlot.bytecode of the next opcode to decode.
    var ip: Int = 0

    /// If non-zero, `ip` will be set to this value at the start of the
    /// next tick (applies GOTO_TAG and PURGE rewinds). See ads.c:765.
    var nextGotoOffset: Int = 0

    // ---------------------------------------------------------------
    // MARK: Timing
    // ---------------------------------------------------------------

    /// Ticks to wait between UPDATE calls. Default 4 (from adsAddScene,
    /// ads.c:247). SET_DELAY and TIMER opcodes update this.
    var delay: Int = 4

    /// Countdown until this thread's next ttmPlay() call.
    var timer: Int = 0

    // ---------------------------------------------------------------
    // MARK: Scene-level timers / counters
    // ---------------------------------------------------------------

    /// If ADD_SCENE arg3 < 0, this is the remaining duration in ticks.
    /// PURGE loops if sceneTimer > 0; marks done otherwise.
    var sceneTimer: Int = 0

    /// If ADD_SCENE arg3 > 0, this is the remaining repeat count
    /// (decremented on each isRunning=2 transition). ads.c:781.
    var sceneIterations: Int = 0

    // ---------------------------------------------------------------
    // MARK: Drawing state
    // ---------------------------------------------------------------

    /// Active BMP slot index (0–5). SET_BMP_SLOT switches this.
    var selectedBmpSlot: Int = 0

    /// Foreground colour index (0–15). Default 0x0F (white).
    var fgColor: UInt8 = 0x0F

    /// Background colour index (0–15). Default 0x0F (white).
    var bgColor: UInt8 = 0x0F

    /// The layer this thread draws into. One layer per thread.
    var layer: Framebuffer = GraphicsState.newLayer()

    // ---------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------

    init() {}

    /// Reset to free state (called by adsStopScene).
    func free() {
        isRunning        = 0
        ttmSlot          = nil
        sceneSlot        = 0
        sceneTag         = 0
        ip               = 0
        nextGotoOffset   = 0
        delay            = 4
        timer            = 0
        sceneTimer       = 0
        sceneIterations  = 0
        selectedBmpSlot  = 0
        fgColor          = 0x0F
        bgColor          = 0x0F
        layer            = GraphicsState.newLayer()
    }
}
