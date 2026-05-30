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

    /// Direct initialiser for programmatic palette construction and testing.
    /// `colors` must contain exactly 16 entries.
    public init(colors: [RGBA]) {
        precondition(colors.count == 16, "EnginePalette requires exactly 16 colors")
        self.colors = colors
    }

    /// Convenience: all-black 16-entry palette (useful as a neutral default
    /// when no resource file is available, e.g. in unit tests).
    public static var black: EnginePalette {
        EnginePalette(colors: Array(repeating: RGBA(r: 0, g: 0, b: 0), count: 16))
    }

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

    /// The palette index that the original game treats as the transparent
    /// colour key. jc_reborn keys on RGB(0xa8, 0, 0xa8) (graphics.c:222);
    /// after our 6-bit→8-bit replication that becomes (0xAA, 0, 0xAA).
    /// Sierra reorders the palette per-game, so we look up the index by
    /// finding the entry closest to that target (Euclidean distance).
    public var transparentIndex: UInt8 {
        let target: (r: Int, g: Int, b: Int) = (0xAA, 0, 0xAA)
        var bestIdx: Int = 0
        var bestDist: Int = .max
        for (i, c) in colors.enumerated() {
            let dr = Int(c.r) - target.r
            let dg = Int(c.g) - target.g
            let db = Int(c.b) - target.b
            let dist = dr*dr + dg*dg + db*db
            if dist < bestDist {
                bestDist = dist
                bestIdx  = i
            }
        }
        return UInt8(bestIdx)
    }
}
