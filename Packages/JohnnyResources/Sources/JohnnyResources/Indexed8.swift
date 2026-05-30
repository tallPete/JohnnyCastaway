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

// Indexed8.swift
//
// Helpers to turn an 8-bit indexed pixel buffer + a Palette into an
// RGBA8 byte buffer. Used by:
//
//   * The Phase 1 PNG diagnostic test — visually confirm the parser
//     extracts recognisable Johnny Castaway imagery.
//   * Phase 4's renderer fragment shader as a CPU reference for tests.
//
// Sierra stored its 256-entry palette as VGA 6-bit-per-channel values
// (range 0..63). To get full 8-bit dynamic range, the low two bits
// must be synthesised. The most common technique is replication:
//
//     out = (value << 2) | (value >> 4)
//
// which maps 63 to 255 exactly and avoids the dim look of a plain
// `value << 2`. This is the default; pass `.raw` to see the
// unprocessed values.

import Foundation

public enum PaletteScaling: Sendable, CaseIterable {
    /// Use raw byte values from the .PAL file. Image will be dim
    /// because values are typically 0..63.
    case raw
    /// Shift left by 2 (multiply by 4). Maps 0..63 to 0..252.
    case vga6BitShifted
    /// Shift left by 2 then OR in the high two bits, replicating
    /// across the low bits. Maps 0..63 to 0..255 with even spacing.
    /// Default; recommended.
    case vga6BitReplicated
}

public struct RGBAImage: Sendable {
    public let width: Int
    public let height: Int
    /// Pixel data, RGBA8 row-major top-left origin. Length = width × height × 4.
    public let pixels: Data

    public init(width: Int, height: Int, pixels: Data) {
        precondition(pixels.count == width * height * 4,
                     "RGBA pixel data must be width * height * 4 bytes")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public enum Indexed8 {

    /// Rasterise an indexed pixel buffer into RGBA8 using the provided
    /// palette and scaling.
    public static func rasterize(
        indexed: Data,
        width: Int,
        height: Int,
        palette: Palette,
        scaling: PaletteScaling = .vga6BitReplicated
    ) -> RGBAImage {
        precondition(indexed.count == width * height,
                     "indexed buffer must be width * height bytes (got \(indexed.count) for \(width)x\(height))")

        // Pre-expand the palette so the inner loop is just three table reads.
        var rTable = [UInt8](repeating: 0, count: 256)
        var gTable = [UInt8](repeating: 0, count: 256)
        var bTable = [UInt8](repeating: 0, count: 256)
        for i in 0 ..< 256 {
            let c = palette.colors[i]
            rTable[i] = expand(c.r, scaling: scaling)
            gTable[i] = expand(c.g, scaling: scaling)
            bTable[i] = expand(c.b, scaling: scaling)
        }

        var out = Data(count: width * height * 4)
        out.withUnsafeMutableBytes { dst in
            indexed.withUnsafeBytes { src in
                let s = src.bindMemory(to: UInt8.self)
                let d = dst.bindMemory(to: UInt8.self)
                for i in 0 ..< (width * height) {
                    let idx = Int(s[i])
                    d[i * 4 + 0] = rTable[idx]
                    d[i * 4 + 1] = gTable[idx]
                    d[i * 4 + 2] = bTable[idx]
                    d[i * 4 + 3] = 0xFF
                }
            }
        }
        return RGBAImage(width: width, height: height, pixels: out)
    }

    @inline(__always)
    private static func expand(_ v: UInt8, scaling: PaletteScaling) -> UInt8 {
        switch scaling {
        case .raw:
            return v
        case .vga6BitShifted:
            return v << 2
        case .vga6BitReplicated:
            // Mirror the high two bits into the low two bits.
            return (v << 2) | (v >> 4)
        }
    }
}

// MARK: - Convenience wrappers on resource types

extension Bitmap {

    /// Rasterise sprite `index` into an RGBAImage using the given
    /// palette.
    public func rasterize(
        sprite index: Int,
        palette: Palette,
        scaling: PaletteScaling = .vga6BitReplicated
    ) -> RGBAImage {
        let w = Int(widths[index])
        let h = Int(heights[index])
        return Indexed8.rasterize(
            indexed: pixels(forSprite: index),
            width: w,
            height: h,
            palette: palette,
            scaling: scaling
        )
    }
}

extension Screen {

    /// Rasterise the entire screen into an RGBAImage using the given
    /// palette.
    public func rasterize(
        palette: Palette,
        scaling: PaletteScaling = .vga6BitReplicated
    ) -> RGBAImage {
        Indexed8.rasterize(
            indexed: pixels,
            width: Int(width),
            height: Int(height),
            palette: palette,
            scaling: scaling
        )
    }
}
