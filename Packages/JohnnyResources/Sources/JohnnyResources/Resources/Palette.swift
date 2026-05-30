// Palette.swift
//
// 256-entry RGB palette (.PAL). Sierra's container is structurally
// 256 colours, but the engine uses only the first 16 for the
// "Johnny Castaway" 16-colour aesthetic. We preserve all 256 so the
// renderer can choose its own subset.
//
// Byte values are preserved as-stored; in practice they are VGA
// 6-bit-per-channel values (range 0..63). Renderers that want full
// 0..255 dynamic range should shift-left by 2.
//
// Translated from `parsePalResource` in `resource.c:183–219`.

import Foundation

public struct Palette: Sendable, Equatable {

    public struct RGB: Sendable, Equatable {
        public let r: UInt8
        public let g: UInt8
        public let b: UInt8

        public init(r: UInt8, g: UInt8, b: UInt8) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    /// 256 RGB triplets, raw byte values from the resource (typically
    /// 0..63 — VGA 6-bit-per-channel encoding).
    public let colors: [RGB]

    /// PAL section size declared in the resource header. Preserved so
    /// downstream tooling can verify the section payload length.
    public let palSize: UInt16

    /// Two unknown bytes following PAL size; values not used by jc_reborn.
    public let palUnknown: [UInt8]

    /// Four bytes following the `VGA:` magic; jc_reborn comments these
    /// as a possible "size" field but the value is not used.
    public let vgaHeaderBytes: [UInt8]

    public init(
        colors: [RGB],
        palSize: UInt16,
        palUnknown: [UInt8],
        vgaHeaderBytes: [UInt8]
    ) {
        precondition(colors.count == 256, "Palette must be exactly 256 colors")
        precondition(palUnknown.count == 2, "PAL unknown bytes must be 2")
        precondition(vgaHeaderBytes.count == 4, "VGA header bytes must be 4")
        self.colors = colors
        self.palSize = palSize
        self.palUnknown = palUnknown
        self.vgaHeaderBytes = vgaHeaderBytes
    }
}
