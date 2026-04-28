// ScreenParser.swift
//
// Translated from `parseScrResource` in `resource.c:222–266`. SCR
// pixel data is 4bpp packed on disk (identical to BMP) and is
// unpacked to 8bpp at parse time so the public `Screen.pixels` is
// uniform 8-bit indexed pixels — `pixels.count == width * height`.
//
// The C reference does the unpack at screen-load time
// (`grLoadScreen` in `graphics.c:531–535`).

import Foundation

enum ScreenParser {

    static func parse(_ reader: inout BinaryReader) throws -> Screen {
        try reader.expectMagic("SCR:")
        let totalSize = try reader.readUInt16LE()
        let flags = try reader.readUInt16LE()

        try reader.expectMagic("DIM:")
        let dimSize = try reader.readUInt32LE()
        let width = try reader.readUInt16LE()
        let height = try reader.readUInt16LE()

        try reader.expectMagic("BIN:")
        let (method, packed) = try reader.readCompressedPayload()

        // 4bpp -> 8bpp unpack, identical to the bitmap path.
        guard width % 2 == 0 else {
            throw ParserError(
                kind: .malformedString,
                offset: 0,
                context: "SCR width \(width) is odd; 4bpp packing requires even widths"
            )
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

        return Screen(
            totalSize: totalSize,
            flags: flags,
            dimSize: dimSize,
            width: width,
            height: height,
            compression: method,
            pixels: unpacked
        )
    }
}
