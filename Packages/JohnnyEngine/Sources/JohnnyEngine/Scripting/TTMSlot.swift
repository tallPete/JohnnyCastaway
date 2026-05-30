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

// TTMSlot.swift
//
// Loaded state for one TTM resource in an ADS run. Holds the
// uncompressed bytecode, the pre-scanned tag offset table, and up to
// MAX_BMP_SLOTS loaded Bitmap references (one per slot).
//
// jc_reborn equivalents: struct TTtmSlot in ttm.h; ttmLoadTtm(),
// ttmInitSlot(), ttmResetSlot() in ttm.c.

import Foundation
import JohnnyResources

/// Maximum number of BMP slots per TTM slot (ADS may load different
/// sprites into different slots; each thread tracks selectedBmpSlot).
let MAX_BMP_SLOTS = 6

/// Maximum number of TTM slots active in one ADS run.
///
/// MUST match jc_reborn (`graphics.h`: `#define MAX_TTM_SLOTS 10`) and the
/// Go port (`MaxTTMSlots`). This was previously 6 — almost certainly copied
/// from MAX_BMP_SLOTS above — which truncated the slot table: visitor/final
/// scenes (VISITOR.ADS, MARY.ADS, …) reference TTM slot id 6, so beginADS
/// silently skipped loading that TTM and adsAddScene then indexed `ttmSlots`
/// out of range. In a debuggable build that traps; inside the legacyScreenSaver
/// host it manifested as a runaway main-thread spin in Swift's exclusivity
/// machinery (the multi-hour "freeze" + black-screen-on-restart).
let MAX_TTM_SLOTS = 10

/// Maximum number of concurrently running TTM threads.
let MAX_TTM_THREADS = 10

/// A tag-to-bytecode-offset mapping, pre-scanned at load time.
struct TTMTagEntry {
    var id: UInt16
    var offset: Int   // post-opcode offset (instruction pointer starts here)
}

/// One loaded TTM resource, ready for interpretation.
final class TTMSlot {

    /// The uncompressed TTM opcode stream.
    var bytecode: Data = Data()

    /// Pre-scanned tag table: entries for every TAG (0x1111) and
    /// LOCAL_TAG (0x1101) in the bytecode, in order. Mirrors jc_reborn's
    /// ttmLoadTtm() pre-scan (ttm.c:86–114).
    var tags: [TTMTagEntry] = []

    /// Loaded bitmaps by slot index. nil = nothing loaded in this slot.
    var bitmaps: [Bitmap?] = Array(repeating: nil, count: MAX_BMP_SLOTS)

    /// Name of the TTM resource that was loaded (for diagnostics).
    var resourceName: String = ""

    var isLoaded: Bool { !bytecode.isEmpty }

    // MARK: ttmFindTag — translate ttmFindTag() in ttm.c:52–69

    /// Return the post-opcode byte offset of `tag` within the bytecode,
    /// or nil if not found. Matches ttmFindTag() (ttm.c:52–69) but
    /// returns nil rather than 0 for a missing tag.
    func findTag(_ tag: UInt16) -> Int? {
        tags.first(where: { $0.id == tag })?.offset
    }

    // MARK: ttmFindPreviousTag — translate ttmFindPreviousTag() in ttm.c:38–49

    /// Return the largest tag offset that is strictly less than `offset`.
    /// This is the "previous tag" used by PURGE to loop back.
    /// Returns 0 if no preceding tag exists.
    func findPreviousTagOffset(before offset: Int) -> Int {
        var result = 0
        for entry in tags {
            if entry.offset < offset {
                result = entry.offset
            } else {
                break
            }
        }
        return result
    }

    // MARK: Load

    /// Populate from a TTMScript resource.
    /// Pre-scans all TAG (0x1111) and LOCAL_TAG (0x1101) opcodes into
    /// `tags`, in bytecode order. Matches ttmLoadTtm() in ttm.c:72–115.
    func load(from script: TTMScript, name: String) {
        bytecode     = script.bytecode
        resourceName = name
        tags         = []
        bitmaps      = Array(repeating: nil, count: MAX_BMP_SLOTS)

        // Pre-scan for tag markers
        var offset = 0
        let data   = bytecode

        while offset < data.count - 1 {
            let opcode = readUInt16LE(data, at: offset)
            offset += 2

            if opcode == 0x1111 || opcode == 0x1101 {
                // arg: uint16 tag id
                guard offset + 1 < data.count else { break }
                let tagId = readUInt16LE(data, at: offset)
                offset += 2
                tags.append(TTMTagEntry(id: tagId, offset: offset))
            } else {
                let numArgs = Int(opcode & 0x000F)
                if numArgs == 0x0F {
                    // String arg — must use the SAME byte-walking algorithm
                    // as the play parser (TTMInterpreter: while data[offset]
                    // != 0; then skip null; then pad to even).
                    //
                    // The previous "look for double null" approach was wrong:
                    // odd-character-count strings (like "NIGHT.SCR" = 9 chars
                    // + 1 null = 10 bytes, no padding) have NO double-null
                    // terminator at the end. The scanner would then walk
                    // past the string into the next opcode's bytes, losing
                    // sync, miscounting all subsequent tag offsets, and
                    // making findTag(N) return wrong byte positions for any
                    // tag past a string opcode. The visible symptom: a
                    // concurrent thread spawned at tag 80 would actually
                    // run unrelated bytecode (often re-drawing Johnny
                    // instead of the secondary element like fire/octopus).
                    while offset < data.count && data[offset] != 0 {
                        offset += 1
                    }
                    if offset < data.count { offset += 1 } // skip the null
                    if offset % 2 != 0 { offset += 1 }     // pad to even
                } else {
                    offset += numArgs * 2
                }
            }
        }

        // SASKDATE.TTM workaround: if we found fewer tags than declared
        // in the script, pad with id=0. Mirrors ttm.c:112–114.
        let declared = script.tags.count
        while tags.count < declared {
            tags.append(TTMTagEntry(id: 0, offset: 0))
        }
    }

    func reset() {
        bytecode     = Data()
        tags         = []
        bitmaps      = Array(repeating: nil, count: MAX_BMP_SLOTS)
        resourceName = ""
    }
}

// MARK: - LE uint16 helper (engine-internal)

@inline(__always)
func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
    let lo = UInt16(data[offset])
    let hi = UInt16(data[offset + 1])
    return lo | (hi << 8)
}
