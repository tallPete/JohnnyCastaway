// Screen.swift
//
// Full-screen indexed-colour background (.SCR). The canonical
// container has dimensions 640×480 for runtime backgrounds plus a
// 640×350 Sierra logo (`JOFFICE.SCR`). On disk the pixel data is
// 4bpp packed (two pixels per byte, high nibble first); the parser
// unpacks to 8bpp so `pixels.count == width * height`.
//
// Translated from `parseScrResource` in `resource.c:222–266`.

import Foundation

public struct Screen: Sendable, Equatable {

    /// Total declared section size (uint16 from the SCR header).
    public let totalSize: UInt16

    /// Flags field (uint16 from the SCR header). Semantics not used
    /// by jc_reborn; preserved for completeness.
    public let flags: UInt16

    /// Declared DIM section size.
    public let dimSize: UInt32

    public let width: UInt16
    public let height: UInt16

    /// Compression method that was applied to the pixel data on disk.
    public let compression: CompressionMethod

    /// Decompressed indexed pixel data, row-major, top-left origin.
    /// Length should equal `width * height` bytes; verify via
    /// `expectedPixelCount`.
    public let pixels: Data

    public init(
        totalSize: UInt16,
        flags: UInt16,
        dimSize: UInt32,
        width: UInt16,
        height: UInt16,
        compression: CompressionMethod,
        pixels: Data
    ) {
        self.totalSize = totalSize
        self.flags = flags
        self.dimSize = dimSize
        self.width = width
        self.height = height
        self.compression = compression
        self.pixels = pixels
    }

    public var expectedPixelCount: Int {
        Int(width) * Int(height)
    }
}
