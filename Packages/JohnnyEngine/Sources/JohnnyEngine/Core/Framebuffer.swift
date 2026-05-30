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

// Framebuffer.swift
//
// 640×480 indexed-colour buffer: the engine's output. Each byte is a
// palette index 0..15 (or 0xFF for "transparent / unwritten" when used
// as a layer). A clip rectangle limits drawing operations to a
// sub-region; set to the full canvas by default.
//
// This is the engine's equivalent of an SDL_Surface with the 8-bit
// indexed pixel layout. jc_reborn uses 32bpp RGBA SDL surfaces plus a
// colour-key; we stay indexed all the way from parse to Metal upload.

/// 640×480 indexed framebuffer plus a current clipping rectangle.
public struct Framebuffer: Sendable {

    public static let width: Int  = 640
    public static let height: Int = 480

    /// Pixel data, row-major, top-left origin. Length == width × height.
    /// Byte values are palette indices 0..15 for drawn pixels;
    /// 0xFF is the transparency sentinel used by Layer (never a valid
    /// palette index in the Johnny Castaway 16-colour engine).
    public var pixels: [UInt8]

    /// Active clip rectangle. Drawing calls must clamp to this region.
    public var clipRect: ClipRect

    public init() {
        pixels   = [UInt8](repeating: 0, count: Framebuffer.width * Framebuffer.height)
        clipRect = ClipRect.full
    }

    /// Initialise with a specific fill value (useful for tests / layer init).
    public init(filledWith value: UInt8) {
        pixels   = [UInt8](repeating: value, count: Framebuffer.width * Framebuffer.height)
        clipRect = ClipRect.full
    }

    /// Read/write a pixel at (x, y) **without** clip checking.
    @inline(__always)
    public func unsafeGet(x: Int, y: Int) -> UInt8 {
        pixels[y &* Framebuffer.width &+ x]
    }

    @inline(__always)
    public mutating func unsafeSet(x: Int, y: Int, to value: UInt8) {
        pixels[y &* Framebuffer.width &+ x] = value
    }

    /// Put a pixel, clamped to the current clip rect.
    @inline(__always)
    public mutating func putPixel(x: Int, y: Int, color: UInt8) {
        guard clipRect.contains(x: x, y: y) else { return }
        unsafeSet(x: x, y: y, to: color)
    }

    /// Clear the entire framebuffer to `value`, ignoring clip rect.
    public mutating func clearAll(to value: UInt8 = 0xFF) {
        pixels = [UInt8](repeating: value, count: Framebuffer.width * Framebuffer.height)
    }

    /// Clear the current clip rect region to `value`.
    public mutating func clearClipped(to value: UInt8 = 0xFF) {
        for y in clipRect.y1 ..< clipRect.y2 {
            let row = y * Framebuffer.width
            for x in clipRect.x1 ..< clipRect.x2 {
                pixels[row + x] = value
            }
        }
    }

    /// Copy the region defined by `src` into `dest` on `self`.
    public mutating func blit(
        from source: Framebuffer,
        srcRect: ClipRect,
        dstX: Int, dstY: Int
    ) {
        for row in 0 ..< srcRect.height {
            let sy = srcRect.y1 + row
            let dy = dstY + row
            guard dy >= 0 && dy < Framebuffer.height else { continue }
            for col in 0 ..< srcRect.width {
                let sx = srcRect.x1 + col
                let dx = dstX + col
                guard dx >= 0 && dx < Framebuffer.width else { continue }
                let px = source.pixels[sy * Framebuffer.width + sx]
                if px != 0xFF { // skip transparent sentinel
                    pixels[dy * Framebuffer.width + dx] = px
                }
            }
        }
    }

    /// Composite `layer` on top of this framebuffer (transparent pixels skipped).
    public mutating func composite(layer: Framebuffer) {
        let n = pixels.count
        for i in 0 ..< n {
            let px = layer.pixels[i]
            if px != 0xFF {
                pixels[i] = px
            }
        }
    }
}

// MARK: - ClipRect

/// An axis-aligned integer rectangle with inclusive-minimum /
/// exclusive-maximum bounds. Matches the SDL_Rect model.
public struct ClipRect: Sendable, Equatable {

    public var x1, y1, x2, y2: Int

    public static let full = ClipRect(
        x1: 0, y1: 0,
        x2: Framebuffer.width,
        y2: Framebuffer.height
    )

    public init(x1: Int, y1: Int, x2: Int, y2: Int) {
        self.x1 = x1; self.y1 = y1
        self.x2 = x2; self.y2 = y2
    }

    @inline(__always)
    public func contains(x: Int, y: Int) -> Bool {
        x >= x1 && x < x2 && y >= y1 && y < y2
    }

    public var width:  Int { x2 - x1 }
    public var height: Int { y2 - y1 }
}
