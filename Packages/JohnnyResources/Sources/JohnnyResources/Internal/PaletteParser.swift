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
