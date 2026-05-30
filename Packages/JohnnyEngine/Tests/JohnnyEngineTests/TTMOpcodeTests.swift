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

// TTMOpcodeTests.swift
//
// Unit tests for the TTM bytecode interpreter. Each test constructs a
// minimal bytecode buffer and asserts the interpreter produces the
// expected state change. No canonical resource files needed.
//
// Bytecode format reminder:
//   uint16 opcode, [uint16 arg0 .. argN], UPDATE (0x0FF0) to stop.
//   All values little-endian.

import Testing
import Foundation
import JohnnyResources
@testable import JohnnyEngine

// MARK: - Helpers

private func u16LE(_ v: UInt16) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8(v >> 8)]
}

// Safe Int → UInt16 helper: truncates to 16 bits without overflow trap.
private func u16LE(_ v: Int) -> [UInt8] { u16LE(UInt16(truncatingIfNeeded: v)) }

private let UPDATE: [UInt8] = u16LE(0x0FF0)

/// Build a TTMSlot from raw bytecode bytes and optionally pre-tag it.
private func makeSlot(bytecode: [UInt8]) -> TTMSlot {
    let slot = TTMSlot()
    // We skip the TTMScript struct and load raw bytecode directly for test simplicity
    slot.bytecode = Data(bytecode)
    // Pre-scan tags (mimics TTMSlot.load behaviour)
    var offset = 0
    while offset + 1 < bytecode.count {
        let op = UInt16(bytecode[offset]) | (UInt16(bytecode[offset + 1]) << 8)
        offset += 2
        if op == 0x1111 || op == 0x1101 {
            if offset + 1 < bytecode.count {
                let id = UInt16(bytecode[offset]) | (UInt16(bytecode[offset + 1]) << 8)
                offset += 2
                slot.tags.append(TTMTagEntry(id: id, offset: offset))
            }
        } else {
            let n = Int(op & 0x000F)
            if n == 0x0F {
                while offset + 1 < bytecode.count && !(bytecode[offset] == 0 && bytecode[offset+1] == 0) {
                    offset += 1
                }
                offset += 2
                if offset % 2 != 0 { offset += 1 }
            } else {
                offset += n * 2
            }
        }
    }
    return slot
}

private func makeThread(slot: TTMSlot) -> TTMThread {
    let t = TTMThread()
    t.ttmSlot   = slot
    t.isRunning = 1
    t.delay     = 4
    t.timer     = 0
    return t
}


import JohnnyResources

extension ResourceCache {
    static func empty() -> ResourceCache {
        let archive = ResourceArchive(
            map: ResourceMap(
                unknownBytes: [0, 0, 0, 0, 0, 0],
                containerFilename: "RESOURCE.001",
                entries: []
            ),
            entries: []
        )
        return ResourceCache(archive: archive)
    }
}

private func runOp(
    _ bytecode: [UInt8],
    before setup: ((TTMThread, GraphicsState) -> Void)? = nil
) -> (TTMThread, GraphicsState) {
    let slot   = makeSlot(bytecode: bytecode)
    let thread = makeThread(slot: slot)
    let g      = GraphicsState()
    let cache  = ResourceCache.empty()
    setup?(thread, g)
    TTMInterpreter.play(
        thread: thread,
        graphics: g,
        cache: cache,
        sound: NullSoundSink()
    )
    return (thread, g)
}

// MARK: - Test Suite

@Suite("TTM opcode interpreter")
struct TTMOpcodeTests {

    @Test("SET_DELAY clamps to minimum 4 ticks")
    func setDelayClamp() {
        // SET_DELAY 2 → should clamp to 4
        let code: [UInt8] = u16LE(0x1021) + u16LE(2) + UPDATE
        let (t, _) = runOp(code)
        #expect(t.delay == 4)
    }

    @Test("SET_DELAY above minimum is accepted as-is")
    func setDelayAboveMin() {
        let code: [UInt8] = u16LE(0x1021) + u16LE(20) + UPDATE
        let (t, _) = runOp(code)
        #expect(t.delay == 20)
    }

    @Test("SET_BMP_SLOT selects the right slot")
    func setBmpSlot() {
        let code: [UInt8] = u16LE(0x1051) + u16LE(3) + UPDATE
        let (t, _) = runOp(code)
        #expect(t.selectedBmpSlot == 3)
    }

    @Test("SET_COLORS updates fg and bg")
    func setColors() {
        let code: [UInt8] = u16LE(0x2002) + u16LE(5) + u16LE(10) + UPDATE
        let (t, _) = runOp(code)
        #expect(t.fgColor == 5)
        #expect(t.bgColor == 10)
    }

    @Test("TIMER sets delay to (arg0 + arg1) / 2")
    func timerFormula() {
        let code: [UInt8] = u16LE(0x2022) + u16LE(8) + u16LE(12) + UPDATE
        let (t, _) = runOp(code)
        #expect(t.delay == 10)  // (8+12)/2
    }

    @Test("DRAW_PIXEL writes fgColor at (x+dx, y+dy)")
    func drawPixel() {
        let code: [UInt8] = u16LE(0xA002) + u16LE(10) + u16LE(20) + UPDATE
        let (t, _) = runOp(code) { th, _ in th.fgColor = 3 }
        #expect(t.layer.unsafeGet(x: 10, y: 20) == 3)
    }

    @Test("DRAW_RECT fills 4×3 region with fgColor")
    func drawRect() {
        let code: [UInt8] = u16LE(0xA104) + u16LE(5) + u16LE(5) + u16LE(4) + u16LE(3) + UPDATE
        let (t, _) = runOp(code) { th, _ in th.fgColor = 7 }
        for row in 5 ..< 8 {
            for col in 5 ..< 9 {
                #expect(t.layer.unsafeGet(x: col, y: row) == 7,
                        "pixel (\(col),\(row)) not drawn")
            }
        }
    }

    @Test("DRAW_LINE draws horizontal line")
    func drawLine() {
        let code: [UInt8] = u16LE(0xA0A4) + u16LE(0) + u16LE(10) + u16LE(5) + u16LE(10) + UPDATE
        let (t, _) = runOp(code) { th, _ in th.fgColor = 2 }
        for x in 0 ..< 5 {
            #expect(t.layer.unsafeGet(x: x, y: 10) == 2, "pixel (\(x),10) missing")
        }
    }

    @Test("DRAW_SPRITE blits indexed pixels from loaded BMP")
    func drawSprite() throws {
        // Load a tiny 2×2 bitmap into slot 0 of the TTMSlot
        let pixels = Data([1, 2, 3, 4])
        let bmp = Bitmap(
            bbWidth: 2, bbHeight: 2,
            dataSize: 0,
            widths: [2], heights: [2],
            compression: .rle,
            pixels: pixels
        )

        // DRAW_SPRITE x=5, y=5, spriteNo=0, imageNo=0
        let code: [UInt8] = u16LE(0xA504) + u16LE(5) + u16LE(5) + u16LE(0) + u16LE(0) + UPDATE
        let (t, _) = runOp(code) { th, _ in
            th.ttmSlot?.bitmaps[0] = bmp
            th.selectedBmpSlot = 0
        }
        #expect(t.layer.unsafeGet(x: 5, y: 5) == 1)
        #expect(t.layer.unsafeGet(x: 6, y: 5) == 2)
        #expect(t.layer.unsafeGet(x: 5, y: 6) == 3)
        #expect(t.layer.unsafeGet(x: 6, y: 6) == 4)
    }

    @Test("DRAW_SPRITE_FLIP mirrors BMP horizontally")
    func drawSpriteFlip() throws {
        let pixels = Data([1, 2, 3, 4])
        let bmp = Bitmap(
            bbWidth: 2, bbHeight: 2, dataSize: 0,
            widths: [2], heights: [2], compression: .rle, pixels: pixels
        )
        let code: [UInt8] = u16LE(0xA524) + u16LE(5) + u16LE(5) + u16LE(0) + u16LE(0) + UPDATE
        let (t, _) = runOp(code) { th, _ in
            th.ttmSlot?.bitmaps[0] = bmp
            th.selectedBmpSlot = 0
        }
        // Flipped: col 0 → x=6, col 1 → x=5
        #expect(t.layer.unsafeGet(x: 6, y: 5) == 1)
        #expect(t.layer.unsafeGet(x: 5, y: 5) == 2)
        #expect(t.layer.unsafeGet(x: 6, y: 6) == 3)
        #expect(t.layer.unsafeGet(x: 5, y: 6) == 4)
    }

    @Test("CLEAR_SCREEN resets layer to 0xFF sentinel")
    func clearScreen() {
        let code: [UInt8] = u16LE(0xA601) + u16LE(0) + UPDATE
        let (t, _) = runOp(code) { th, _ in
            th.layer.pixels[0] = 5
        }
        #expect(t.layer.pixels[0] == 0xFF)
    }

    @Test("SET_CLIP_ZONE updates layer clip rect")
    func setClipZone() {
        let code: [UInt8] = u16LE(0x4004) + u16LE(10) + u16LE(10) + u16LE(200) + u16LE(200) + UPDATE
        let (t, _) = runOp(code)
        #expect(t.layer.clipRect.x1 == 10)
        #expect(t.layer.clipRect.y1 == 10)
        #expect(t.layer.clipRect.x2 == 200)
        #expect(t.layer.clipRect.y2 == 200)
    }

    @Test("GOTO_TAG schedules a jump to tag 1")
    func gotoTag() {
        // Bytecode: TAG 1 (no-op), GOTO_TAG 1 → nextGotoOffset = 4, UPDATE.
        // The tag-scan bookmarks TAG 1 at offset 4 (post-arg position).
        // GOTO_TAG 1 looks up the tag and sets nextGotoOffset to 4.
        let tagOffset = 4  // offset immediately after the TAG 1 opcode+arg
        let code: [UInt8] =
            u16LE(0x1111) + u16LE(1) +   // :TAG 1 (offset 4 post-scan)
            u16LE(0x1201) + u16LE(1) +   // GOTO_TAG 1 → nextGotoOffset = 4
            UPDATE
        let (t, _) = runOp(code)
        #expect(t.nextGotoOffset == tagOffset)
    }

    @Test("PURGE with sceneTimer > 0 schedules rewind to previous tag")
    func purgeWithTimer() {
        // TAG 1 at bytecode offset 4, then PURGE, UPDATE
        let code: [UInt8] =
            u16LE(0x1111) + u16LE(1) +   // :TAG 1
            u16LE(0x0110) +               // PURGE
            UPDATE
        let (t, _) = runOp(code) { th, _ in
            th.sceneTimer = 100   // has time remaining
        }
        // PURGE should have set nextGotoOffset to previous tag offset (4 = after TAG 1)
        #expect(t.nextGotoOffset == 4)
        #expect(t.isRunning == 1)         // still running
    }

    @Test("PURGE with sceneTimer == 0 marks thread done")
    func purgeWithNoTimer() {
        let code: [UInt8] = u16LE(0x0110) + UPDATE
        let (t, _) = runOp(code) { th, _ in
            th.sceneTimer = 0   // no time remaining
        }
        #expect(t.isRunning == 2)
    }

    @Test("UPDATE stops the interpret loop without marking done")
    func updateYields() {
        let code: [UInt8] = UPDATE
        let (t, _) = runOp(code)
        #expect(t.isRunning == 1)   // still running
        #expect(t.ip == 2)          // advanced past UPDATE opcode
    }

    @Test("EOF without UPDATE marks thread done")
    func eofMarksDone() {
        let code: [UInt8] = u16LE(0x2002) + u16LE(1) + u16LE(2)
        // No UPDATE at end → will run off EOF
        let (t, _) = runOp(code)
        #expect(t.isRunning == 2)
    }
}
