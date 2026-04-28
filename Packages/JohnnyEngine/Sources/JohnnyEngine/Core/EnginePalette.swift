// EnginePalette.swift
//
// 16-entry RGB palette for engine rendering. Wraps the 256-entry
// JohnnyResources.Palette, extracting the first 16 entries and expanding
// the 6-bit VGA channel values to full 8-bit range.
//
// VGA 6-bit to 8-bit expansion: replicate the high 2 bits in the low 2
// positions — e.g. value 0x3F (63) → 0xFF (255). Formula:
//   out = (v << 2) | (v >> 4)
// This is the same as PaletteScaling.vga6BitReplicated in JohnnyResources.
//
// jc_reborn reference: grLoadPalette() in graphics.c:99–110 uses `v << 2`,
// i.e. the simpler left-shift form. We use replication for accuracy,
// matching the Phase 1 Indexed8.swift convention already established.

import JohnnyResources

/// A 16-entry RGBA engine palette extracted from a JohnnyResources Palette.
public struct EnginePalette: Sendable {

    public struct RGBA: Sendable {
        public let r, g, b: UInt8
        public var a: UInt8 = 255
        public init(r: UInt8, g: UInt8, b: UInt8) {
            self.r = r; self.g = g; self.b = b
        }
    }

    /// 16 engine colours. Index 0 is colour 0, index 15 is colour 15.
    public let colors: [RGBA]   // exactly 16 entries

    /// Build from a JohnnyResources.Palette, expanding VGA 6-bit values.
    public init(from palette: Palette) {
        var out = [RGBA]()
        out.reserveCapacity(16)
        for i in 0 ..< 16 {
            let c = palette.colors[i]
            out.append(RGBA(
                r: EnginePalette.expand6(c.r),
                g: EnginePalette.expand6(c.g),
                b: EnginePalette.expand6(c.b)
            ))
        }
        colors = out
    }

    @inline(__always)
    private static func expand6(_ v: UInt8) -> UInt8 {
        // (v << 2) | (v >> 4) — exact match for PaletteScaling.vga6BitReplicated
        return (v << 2) | (v >> 4)
    }
}
