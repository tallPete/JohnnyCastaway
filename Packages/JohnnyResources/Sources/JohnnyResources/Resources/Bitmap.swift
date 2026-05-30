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

// Bitmap.swift
//
// Multi-sprite atlas (.BMP). Each entry holds a number of variable-
// sized sprites concatenated in `pixels`. Per-sprite dimensions are
// in `widths` / `heights`; the offset of sprite N within `pixels` is
// the sum of widths[i] * heights[i] for i < N.
//
// Bit depth: every Bitmap in the canonical container is stored on
// disk as **4 bits per pixel, two pixels per byte, high-nibble first**.
// All 113 canonical BMPs verified to have this layout. The Bitmap
// parser unpacks 4bpp → 8bpp at parse time so callers see uniform
// 8-bit indexed pixel data — i.e. `pixels.count == sum(widths[i] *
// heights[i])`.
//
// The C reference (`grLoadBmp` in `graphics.c:568–601`) does the same
// unpack at sprite-load time and rejects odd widths. We do the same:
// odd widths throw `ParserError(.malformedString)` because they would
// indicate a layout we don't understand.
//
// Translated from `parseBmpResource` in `resource.c:134–180` plus the
// `grLoadBmp` unpack loop.

import Foundation

public struct Bitmap: Sendable, Equatable {

    /// Atlas-level dimensions (the largest sprite, typically). Not
    /// strictly needed for sprite extraction but preserved.
    public let bbWidth: UInt16
    public let bbHeight: UInt16

    /// Total INF-section payload size (uint32 from the BMP header).
    public let dataSize: UInt32

    /// Per-sprite dimensions. `widths.count == heights.count == numImages`.
    public let widths: [UInt16]
    public let heights: [UInt16]

    public let compression: CompressionMethod

    /// Concatenated indexed pixel data for all sprites in declaration
    /// order. Use `pixels(forSprite:)` to slice.
    public let pixels: Data

    public init(
        bbWidth: UInt16,
        bbHeight: UInt16,
        dataSize: UInt32,
        widths: [UInt16],
        heights: [UInt16],
        compression: CompressionMethod,
        pixels: Data
    ) {
        precondition(widths.count == heights.count, "widths/heights must be parallel arrays")
        self.bbWidth = bbWidth
        self.bbHeight = bbHeight
        self.dataSize = dataSize
        self.widths = widths
        self.heights = heights
        self.compression = compression
        self.pixels = pixels
    }

    public var imageCount: Int { widths.count }

    /// Byte offset of sprite `index` within `pixels`.
    public func pixelOffset(forSprite index: Int) -> Int {
        precondition((0 ..< imageCount).contains(index), "sprite index out of range")
        var offset = 0
        for i in 0 ..< index {
            offset += Int(widths[i]) * Int(heights[i])
        }
        return offset
    }

    /// Sliced pixel data for sprite `index`, length = width * height.
    public func pixels(forSprite index: Int) -> Data {
        let offset = pixelOffset(forSprite: index)
        let length = Int(widths[index]) * Int(heights[index])
        return pixels.subdata(in: offset ..< offset + length)
    }

    /// Combined width × height of every declared sprite. Should equal
    /// `pixels.count`. (Diagnostic use; the parser does not enforce.)
    public var totalSpritePixelBytes: Int {
        var total = 0
        for i in 0 ..< imageCount {
            total += Int(widths[i]) * Int(heights[i])
        }
        return total
    }
}
