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

// CompressedPayload.swift
//
// Helper used by every compressing resource type (SCR, BMP, TTM, ADS).
// The on-disk layout is:
//
//   uint32  totalSize        // includes method byte + uncompressedSize uint32
//   uint8   method           // 1 = RLE, 2 = LZW
//   uint32  uncompressedSize
//   ... compressed payload of (totalSize - 5) bytes ...
//
// This helper reads those four fields, decompresses the payload, and
// returns the (method, decompressedData) pair.

import Foundation

extension BinaryReader {

    /// Read the standard "compressed payload" sub-section and return
    /// the decompressed bytes plus the method that was used.
    mutating func readCompressedPayload() throws -> (CompressionMethod, Data) {
        let startOffset = cursor
        let totalSize = try readUInt32LE()
        let methodByte = try readUInt8()
        let uncompressedSize = try readUInt32LE()

        guard let method = CompressionMethod(rawValue: methodByte) else {
            throw ParserError(
                kind: .unsupportedCompression(method: methodByte),
                offset: startOffset + 4,
                context: context
            )
        }

        // The 5 bytes are the method byte + the uncompressedSize uint32.
        let payloadByteLength = Int(totalSize) - 5
        guard payloadByteLength >= 0 else {
            throw ParserError(
                kind: .truncated(needed: 0, available: payloadByteLength),
                offset: startOffset,
                context: context
            )
        }

        let payload = try readBytes(payloadByteLength)
        let decompressed = try Decompressor.decompress(
            method: method,
            source: payload,
            expectedSize: Int(uncompressedSize),
            context: context
        )
        return (method, decompressed)
    }
}
