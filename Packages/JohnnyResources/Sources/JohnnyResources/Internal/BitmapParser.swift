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

// BitmapParser.swift
//
// Translated from `parseBmpResource` in `resource.c:134–180`.

import Foundation

enum BitmapParser {

    static func parse(_ reader: inout BinaryReader) throws -> Bitmap {
        try reader.expectMagic("BMP:")
        let bbWidth = try reader.readUInt16LE()
        let bbHeight = try reader.readUInt16LE()

        try reader.expectMagic("INF:")
        let dataSize = try reader.readUInt32LE()
        let numImages = try reader.readUInt16LE()

        var widths: [UInt16] = []
        widths.reserveCapacity(Int(numImages))
        for _ in 0 ..< numImages {
            widths.append(try reader.readUInt16LE())
        }

        var heights: [UInt16] = []
        heights.reserveCapacity(Int(numImages))
        for _ in 0 ..< numImages {
            heights.append(try reader.readUInt16LE())
        }

        try reader.expectMagic("BIN:")
        let (method, packed) = try reader.readCompressedPayload()

        // Unpack 4bpp -> 8bpp. Each input byte expands to two output
        // bytes: high nibble first, then low nibble. Reject odd widths
        // because the C reference does (it can't decode them either)
        // and it would mean we don't understand the on-disk layout.
        for (i, w) in widths.enumerated() {
            if w % 2 != 0 {
                throw ParserError(
                    kind: .malformedString,
                    offset: 0,
                    context: "BMP sprite \(i) has odd width \(w); 4bpp packing requires even widths"
                )
            }
        }

        var unpacked = Data(capacity: packed.count * 2)
        packed.withUnsafeBytes { src in
            let s = src.bindMemory(to: UInt8.self)
            for i in 0 ..< packed.count {
                let b = s[i]
                unpacked.append((b & 0xF0) >> 4)
                unpacked.append(b & 0x0F)
            }
        }

        return Bitmap(
            bbWidth: bbWidth,
            bbHeight: bbHeight,
            dataSize: dataSize,
            widths: widths,
            heights: heights,
            compression: method,
            pixels: unpacked
        )
    }
}
