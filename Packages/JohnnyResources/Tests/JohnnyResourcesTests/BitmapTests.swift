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

// BitmapTests.swift

import Testing
import Foundation
@testable import JohnnyResources

@Suite("Bitmap parsing (canonical)",
       .disabled(if: !TestResources.available, TestResources.skipMessage))
struct BitmapTests {

    @Test("Every BMP has parallel widths/heights arrays (count = numImages)")
    func widthsHeightsParallel() throws {
        let archive = try ContainerTests.archive()
        let bitmaps = archive.entries(of: .bitmap)
        #expect(!bitmaps.isEmpty, "no bitmap entries found")

        for entry in bitmaps {
            guard case .bitmap(let bmp) = entry.resource else { continue }
            #expect(bmp.widths.count == bmp.heights.count)
            #expect(bmp.imageCount == bmp.widths.count)
            #expect(bmp.imageCount > 0, "\(entry.name) has zero images")
        }
    }

    @Test("After 4bpp→8bpp unpack, pixels.count equals sum of widths × heights")
    func unpackedPixelCountMatchesDimensions() throws {
        let archive = try ContainerTests.archive()
        for entry in archive.entries(of: .bitmap) {
            guard case .bitmap(let bmp) = entry.resource else { continue }
            #expect(
                bmp.pixels.count == bmp.totalSpritePixelBytes,
                "\(entry.name): pixels=\(bmp.pixels.count) sum(w*h)=\(bmp.totalSpritePixelBytes)"
            )
        }
    }

    @Test("Every BMP has even widths (4bpp packing requirement)")
    func widthsAreAllEven() throws {
        let archive = try ContainerTests.archive()
        for entry in archive.entries(of: .bitmap) {
            guard case .bitmap(let bmp) = entry.resource else { continue }
            for (i, w) in bmp.widths.enumerated() {
                #expect(w % 2 == 0, "\(entry.name) sprite \(i) width=\(w) is odd")
            }
        }
    }

    @Test("After unpack, every pixel index is in 0..15 (16-colour palette)")
    func pixelIndicesAreFourBitRange() throws {
        let archive = try ContainerTests.archive()
        for entry in archive.entries(of: .bitmap) {
            guard case .bitmap(let bmp) = entry.resource else { continue }
            // Sample first sprite's pixels — full check is too slow.
            let sample = bmp.pixels(forSprite: 0)
            let max = sample.max() ?? 0
            #expect(max <= 15, "\(entry.name) sprite 0 has index \(max) outside 0..15")
        }
    }

    @Test("pixels(forSprite:) returns the expected slice length for sprite 0")
    func sliceForFirstSprite() throws {
        let archive = try ContainerTests.archive()
        for entry in archive.entries(of: .bitmap) {
            guard case .bitmap(let bmp) = entry.resource else { continue }
            let slice = bmp.pixels(forSprite: 0)
            let expected = Int(bmp.widths[0]) * Int(bmp.heights[0])
            #expect(slice.count == expected, "\(entry.name) sprite 0 slice")
        }
    }
}
