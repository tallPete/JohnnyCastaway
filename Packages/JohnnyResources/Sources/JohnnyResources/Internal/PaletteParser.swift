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

// PaletteParser.swift
//
// Translated from `parsePalResource` in `resource.c:183–219`.

import Foundation

enum PaletteParser {

    static func parse(_ reader: inout BinaryReader) throws -> Palette {
        try reader.expectMagic("PAL:")
        let palSize = try reader.readUInt16LE()
        let palU1 = try reader.readUInt8()
        let palU2 = try reader.readUInt8()

        try reader.expectMagic("VGA:")
        let vga0 = try reader.readUInt8()
        let vga1 = try reader.readUInt8()
        let vga2 = try reader.readUInt8()
        let vga3 = try reader.readUInt8()

        var colors: [Palette.RGB] = []
        colors.reserveCapacity(256)
        for _ in 0 ..< 256 {
            let r = try reader.readUInt8()
            let g = try reader.readUInt8()
            let b = try reader.readUInt8()
            colors.append(.init(r: r, g: g, b: b))
        }

        return Palette(
            colors: colors,
            palSize: palSize,
            palUnknown: [palU1, palU2],
            vgaHeaderBytes: [vga0, vga1, vga2, vga3]
        )
    }
}
