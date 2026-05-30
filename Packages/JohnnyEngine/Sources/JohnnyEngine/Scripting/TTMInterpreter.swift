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

// TTMInterpreter.swift
//
// TTM bytecode interpreter. Translates ttmPlay() from ttm.c:141–352
// and ttmLoadTtm() from ttm.c:72–115 (load side is in TTMSlot.load()).
//
// One call to TTMInterpreter.play(thread:graphics:cache:sound:) advances
// `thread` by one batch of opcodes, stopping when it hits:
//   • UPDATE (0x0FF0) — yield; caller will composite and sleep
//   • end of bytecode — sets thread.isRunning = 2 (done)
//
// PURGE (0x0110): if sceneTimer > 0, schedules a rewind to the previous
// tag via nextGotoOffset; does NOT stop the loop (matches C behaviour
// where the loop only stops at UPDATE or EOF).
//
// String opcode args (low nibble == 0xF): read until byte == 0, then
// pad to even boundary. Translates ttm.c:166–177.

import Foundation
import JohnnyResources

/// Stateless interpreter: all mutable state lives in TTMThread and
/// GraphicsState. Each call advances one thread by one UPDATE tick.
enum TTMInterpreter {

    // ---------------------------------------------------------------
    // MARK: Opcode-coverage counter (diagnostic)
    // ---------------------------------------------------------------

    /// Set of opcodes encountered during the current engine run. Reset
    /// by Engine.reset(). Exposed so tests can assert coverage.
    /// Engine is not thread-safe; access is protected by caller.
    nonisolated(unsafe) static var coveredOpcodes: Set<UInt16> = []

    // ---------------------------------------------------------------
    // MARK: play() — translates ttmPlay() in ttm.c:141–352
    // ---------------------------------------------------------------

    static func play(
        thread: TTMThread,
        graphics: GraphicsState,
        cache: ResourceCache,
        sound: SoundSink
    ) {
        guard let slot = thread.ttmSlot, slot.isLoaded else {
            // Log unexpected play() on a thread with no/unloaded TTM slot.
            // The walk thread (ttmSlot == nil) should never reach play() because
            // scheduler.tick() is only called from .playingScene, and walks run in
            // .walking. Seeing this log means a nil-slot thread leaked into
            // scheduler.threads while the scene is active — the upstream cause
            // will appear in nearby [ads] beginADS or [walk] logs.
            let slotDesc = thread.ttmSlot.map { "slot=\($0.resourceName.isEmpty ? "(empty)" : $0.resourceName) isLoaded=\($0.isLoaded)" } ?? "ttmSlot=nil"
            print("[ttm] WARN play() skipped — \(slotDesc) tag=\(thread.sceneTag) ip=\(thread.ip) isRunning=\(thread.isRunning)")
            return
        }
        let data = slot.bytecode

        var offset = thread.ip
        var continueLoop = true

        while continueLoop {
            guard offset + 1 < data.count else {
                // Ran off the end of bytecode → mark done
                print("[ttm] thread done (EOF) slot=\(slot.resourceName) tag=\(thread.sceneTag) ip=\(offset) bytecodeLen=\(data.count)")
                thread.isRunning = 2
                continueLoop = false
                break
            }

            let opcode = readUInt16LE(data, at: offset)
            offset += 2
            coveredOpcodes.insert(opcode)

            let numArgs = Int(opcode & 0x000F)

            // ---- Parse arguments ----
            var args = [UInt16](repeating: 0, count: 10)
            var strArg = ""

            if numArgs == 0x0F {
                // String arg: bytes until null, padded to even boundary.
                // Translates ttm.c:166–177.
                var chars = [Character]()
                while offset < data.count && data[offset] != 0 {
                    chars.append(Character(Unicode.Scalar(data[offset])))
                    offset += 1
                }
                if offset < data.count { offset += 1 } // skip null
                if offset % 2 != 0 { offset += 1 }    // pad to even
                strArg = String(chars)
            } else {
                for i in 0 ..< numArgs {
                    guard offset + 1 < data.count else { break }
                    args[i] = readUInt16LE(data, at: offset)
                    offset += 2
                }
            }

            // ---- Dispatch ----
            switch opcode {

            case 0x0080:   // DRAW_BACKGROUND
                // Free image slots. In practice, jc_reborn does nothing
                // here. We reset bitmaps in all slots for this thread's
                // TTM slot. (ttm.c:184–186)
                break

            case 0x0110:   // PURGE
                // Loop if sceneTimer > 0, else mark done. Does NOT stop
                // the interpret loop. (ttm.c:189–195)
                if thread.sceneTimer > 0 {
                    let jumpTo = slot.findPreviousTagOffset(before: offset)
                    if jumpTo == 0 {
                        // No tag exists before the PURGE — loop-back will be
                        // suppressed by the `nextGotoOffset != 0` guard in
                        // post-process. jc_reborn would jump to ip=0 here;
                        // our nextGotoOffset scheme treats 0 as "no jump".
                        // This is usually benign (thread runs forward to EOF),
                        // but log it so we know it happened.
                        print("[ttm] PURGE loop-back: no prior tag found before ip=\(offset) in slot=\(slot.resourceName) tag=\(thread.sceneTag) — will play through to EOF instead of looping")
                    }
                    thread.nextGotoOffset = jumpTo
                } else {
                    print("[ttm] thread done (PURGE/sceneTimer=0) slot=\(slot.resourceName) tag=\(thread.sceneTag) at_ip=\(offset)")
                    thread.isRunning = 2
                }

            case 0x0FF0:   // UPDATE — yield
                continueLoop = false

            case 0x1021:   // SET_DELAY
                // Clamp to ≥ 4 (ttm.c:203–204 TODO comment).
                let v = Int(args[0])
                thread.delay = max(4, v)
                thread.timer = thread.delay

            case 0x1051:   // SET_BMP_SLOT
                thread.selectedBmpSlot = Int(args[0])

            case 0x1061:   // SET_PALETTE_SLOT
                // Not implemented in jc_reborn either. (ttm.c:213–214)
                break

            case 0x1101:   // LOCAL_TAG marker — execution target, no effect
                break

            case 0x1111:   // TAG marker — execution target, no effect
                break

            case 0x1121:   // TTM_UNKNOWN_1
                // Defines a region id for CLEAR_SCREEN. Ignored.
                break

            case 0x1201:   // GOTO_TAG
                if let dest = slot.findTag(args[0]) {
                    thread.nextGotoOffset = dest
                }

            case 0x2002:   // SET_COLORS
                thread.fgColor = UInt8(args[0] & 0xFF)
                thread.bgColor = UInt8(args[1] & 0xFF)

            case 0x2012:   // SET_FRAME1 — pre-render hint, args always (0,0)
                break

            case 0x2022:   // TIMER
                // Formula from ttm.c:253. Author flagged "really not sure".
                let v = (Int(args[0]) + Int(args[1])) / 2
                thread.delay = v
                thread.timer = v

            case 0x4004:   // SET_CLIP_ZONE
                graphics.setClipZone(
                    on: &thread.layer,
                    x1: Int(Int16(bitPattern: args[0])),
                    y1: Int(Int16(bitPattern: args[1])),
                    x2: Int(Int16(bitPattern: args[2])),
                    y2: Int(Int16(bitPattern: args[3]))
                )

            case 0x4204:   // COPY_ZONE_TO_BG
                graphics.copyZoneToBg(
                    from: thread.layer,
                    x:      Int(Int16(bitPattern: args[0])),
                    y:      Int(Int16(bitPattern: args[1])),
                    width:  Int(args[2]),
                    height: Int(args[3])
                )

            case 0x4214:   // SAVE_IMAGE1 — unused in originals, no-op
                break

            case 0xA002:   // DRAW_PIXEL
                graphics.drawPixel(
                    on: &thread.layer,
                    x: Int(Int16(bitPattern: args[0])),
                    y: Int(Int16(bitPattern: args[1])),
                    color: thread.fgColor
                )

            case 0xA054:   // SAVE_ZONE
                graphics.saveZone(
                    x: Int(Int16(bitPattern: args[0])),
                    y: Int(Int16(bitPattern: args[1])),
                    width:  Int(args[2]),
                    height: Int(args[3])
                )

            case 0xA064:   // RESTORE_ZONE
                graphics.restoreZone()

            case 0xA0A4:   // DRAW_LINE
                graphics.drawLine(
                    on: &thread.layer,
                    x1: Int(Int16(bitPattern: args[0])),
                    y1: Int(Int16(bitPattern: args[1])),
                    x2: Int(Int16(bitPattern: args[2])),
                    y2: Int(Int16(bitPattern: args[3])),
                    color: thread.fgColor
                )

            case 0xA104:   // DRAW_RECT (args: x, y, width, height)
                graphics.drawRect(
                    on: &thread.layer,
                    x:      Int(Int16(bitPattern: args[0])),
                    y:      Int(Int16(bitPattern: args[1])),
                    width:  Int(args[2]),
                    height: Int(args[3]),
                    color: thread.fgColor
                )

            case 0xA404:   // DRAW_CIRCLE (args: x1, y1, width, height)
                graphics.drawCircle(
                    on: &thread.layer,
                    x1:     Int(Int16(bitPattern: args[0])),
                    y1:     Int(Int16(bitPattern: args[1])),
                    width:  Int(args[2]),
                    height: Int(args[3]),
                    fgColor: thread.fgColor,
                    bgColor: thread.bgColor
                )

            case 0xA504:   // DRAW_SPRITE (args: x, y, spriteNo, imageNo)
                // BUG FIX: jc_reborn graphics.c DRAW_SPRITE indexes
                // ttmSlot->sprites[imageNo][spriteNo] — imageNo = args[3]
                // selects WHICH BMP SLOT to draw from. Our previous code
                // used thread.selectedBmpSlot (which is for LOAD_IMAGE to
                // choose where to LOAD INTO), causing DRAW_SPRITE to ignore
                // the bytecode-supplied bitmap selection. Symptoms:
                // "Johnny's torso on the end of the fishing line" (script
                // wanted to draw fish from slot 1 but we drew Johnny from
                // selectedBmpSlot 0); "Lilliputians invisible, multiple
                // Johnnys instead" (each thread's DRAW_SPRITE was supposed
                // to use a different imageNo for its sprite sheet).
                // imageNo (args[3]) selects the BMP slot to draw from
                let bmpSlot = Int(args[3])
                if bmpSlot >= 0 && bmpSlot < MAX_BMP_SLOTS,
                   let bmp = thread.ttmSlot?.bitmaps[bmpSlot] {
                    graphics.drawSprite(
                        on: &thread.layer,
                        bitmap: bmp,
                        x:        Int(Int16(bitPattern: args[0])),
                        y:        Int(Int16(bitPattern: args[1])),
                        spriteNo: Int(args[2]),
                        imageNo:  Int(args[3])
                    )
                }

            case 0xA524:   // DRAW_SPRITE_FLIP — same imageNo semantics
                let bmpSlot = Int(args[3])
                if bmpSlot >= 0 && bmpSlot < MAX_BMP_SLOTS,
                   let bmp = thread.ttmSlot?.bitmaps[bmpSlot] {
                    graphics.drawSpriteFlip(
                        on: &thread.layer,
                        bitmap: bmp,
                        x:        Int(Int16(bitPattern: args[0])),
                        y:        Int(Int16(bitPattern: args[1])),
                        spriteNo: Int(args[2]),
                        imageNo:  Int(args[3])
                    )
                }

            case 0xA601:   // CLEAR_SCREEN
                graphics.clearScreen(layer: &thread.layer)

            case 0xB606:   // DRAW_SCREEN — intentional no-op
                // JCOS draws the LOAD_SCREEN'd SCR onto its flat composite
                // surface. In our layered model, LOAD_SCREEN already stores
                // the SCR in graphics.background and the compositor blits it
                // as the base layer automatically. Blitting it again onto a
                // thread layer overwrites sprites drawn by lower-numbered
                // threads (confirmed: produces a background-shaped patch over
                // the sailing-ship scene). jc_reborn and the Go port both
                // skip this opcode for the same architectural reason.
                break

            case 0xC051:   // PLAY_SAMPLE
                sound.playSample(Int(args[0]))

            case 0xF01F:   // LOAD_SCREEN
                if let scr = try? cache.screen(named: strArg) {
                    print("[ttm] LOAD_SCREEN \(strArg) (slot=\(thread.ttmSlot?.resourceName ?? "?"))")
                    graphics.loadScreen(scr)
                    // A scene that loads its own background (e.g.
                    // ISLAND2.SCR for a fishing close-up) is no longer
                    // working in island-offset coordinates — its sprites
                    // are positioned relative to its own screen, not the
                    // regular ocean island. Reset dx/dy so subsequent
                    // sprite draws aren't shifted by the (now meaningless)
                    // island varPos offset.
                    graphics.dx = 0
                    graphics.dy = 0
                }

            case 0xF02F:   // LOAD_IMAGE
                if let bmp = try? cache.bitmap(named: strArg),
                   let slot2 = thread.ttmSlot {
                    let slotIdx = thread.selectedBmpSlot
                    // Defensive bounds-guard: selectedBmpSlot comes straight from
                    // SET_BMP_SLOT's bytecode arg with no validation, and `bitmaps`
                    // is fixed-size MAX_BMP_SLOTS. Canonical data keeps this in
                    // range (jc_reborn assumes the same), but guard so malformed
                    // data can't index out of range — the same failure class as
                    // the MAX_TTM_SLOTS slot index.
                    if slotIdx >= 0 && slotIdx < MAX_BMP_SLOTS {
                        slot2.bitmaps[slotIdx] = bmp
                    } else {
                        print("[ttm] WARN LOAD_IMAGE: selectedBmpSlot \(slotIdx) out of range (0..<\(MAX_BMP_SLOTS)) — ignoring")
                    }
                }

            case 0xF05F:   // LOAD_PALETTE — no-op as in jc_reborn
                break

            default:
                // Unknown opcode: ignore. jc_reborn does the same.
                break
            }
        }

        thread.ip = offset
    }
}
