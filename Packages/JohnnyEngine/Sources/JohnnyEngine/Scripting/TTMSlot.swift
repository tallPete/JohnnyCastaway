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
let MAX_TTM_SLOTS = 6

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
                    // string arg: advance past null-terminated string (pair-aligned)
                    while offset + 1 < data.count &&
                          !(data[offset] == 0 && data[offset + 1] == 0) {
                        offset += 1
                    }
                    offset += 2 // skip the double-null terminator
                    if offset % 2 != 0 { offset += 1 } // align to even
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
