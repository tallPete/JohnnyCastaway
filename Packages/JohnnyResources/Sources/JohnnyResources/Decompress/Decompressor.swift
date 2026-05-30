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

// Decompressor.swift
//
// Direct ports of jc_reborn's `uncompress.c`. Two compression schemes
// appear in the resource container:
//
//   method 1 — RLE   : 1-byte control header; high bit selects run vs literal
//   method 2 — LZW   : 9-12 bit variable-width codes, 4096-entry table,
//                       LSB-first bit packing, code 256 = clear table
//
// Notable fidelity points kept from the C reference:
//
//   * `getByte` past EOF returns zero rather than failing. This means
//     LZW reads can synthesise trailing zero bytes from beyond the
//     compressed payload — important because some inputs end mid-byte
//     and depend on that zero-padding to terminate cleanly.
//   * After the loop, however, `inOffset` MUST equal `inSize`. This
//     catches truncation and overrun bugs.
//   * The "KwKwK" edge case (decoding a code that hasn't been added to
//     the table yet) is handled by pushing `lastbyte` and re-using
//     `oldcode` as the prefix.
//   * Width grows from 9 to 12 bits when `free_entry >= (1 << n_bits)`.
//   * Code 256 forces the bit cursor to the next byte-aligned 9-bit
//     slot via a calculated skip count.
//
// Decompression is a pure function on the input bytes; no shared mutable
// state, suitable for concurrent calls.

import Foundation

enum Decompressor {

    /// Dispatch on the method byte and decompress.
    static func decompress(
        method: CompressionMethod,
        source: Data,
        expectedSize: Int,
        context: String
    ) throws -> Data {
        let result: Data
        switch method {
        case .rle:
            result = try uncompressRLE(source: source, expectedSize: expectedSize, context: context)
        case .lzw:
            result = try uncompressLZW(source: source, expectedSize: expectedSize, context: context)
        }
        if result.count != expectedSize {
            throw ParserError(
                kind: .decompressedSizeMismatch(expected: expectedSize, got: result.count),
                offset: 0,
                context: context
            )
        }
        return result
    }

    // MARK: - RLE (port of `uncompress.c:180–215`)

    static func uncompressRLE(source: Data, expectedSize: Int, context: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }

        // Materialise into a contiguous byte array for cheap [Int] access.
        let input = Array(source)
        var output = Data(capacity: expectedSize)
        var inOffset = 0

        while output.count < expectedSize {
            guard inOffset < input.count else {
                throw ParserError(
                    kind: .truncated(needed: 1, available: 0),
                    offset: inOffset,
                    context: "\(context) [RLE]"
                )
            }
            let control = input[inOffset]
            inOffset += 1

            if (control & 0x80) == 0x80 {
                // Run: replicate next byte (control & 0x7F) times.
                let length = Int(control & 0x7F)
                guard inOffset < input.count else {
                    throw ParserError(
                        kind: .truncated(needed: 1, available: 0),
                        offset: inOffset,
                        context: "\(context) [RLE run]"
                    )
                }
                let b = input[inOffset]
                inOffset += 1
                let take = min(length, expectedSize - output.count)
                output.append(contentsOf: repeatElement(b, count: take))
            } else {
                // Literal: copy `control` bytes verbatim.
                let length = Int(control)
                guard inOffset + length <= input.count else {
                    throw ParserError(
                        kind: .truncated(needed: length, available: input.count - inOffset),
                        offset: inOffset,
                        context: "\(context) [RLE literal]"
                    )
                }
                let take = min(length, expectedSize - output.count)
                output.append(contentsOf: input[inOffset ..< inOffset + take])
                inOffset += length // NB: we always advance by `length`, even if we clamped output
            }
        }

        if inOffset != input.count {
            throw ParserError(
                kind: .rleInputUnderrun(expected: input.count, consumed: inOffset),
                offset: inOffset,
                context: context
            )
        }

        return output
    }

    // MARK: - LZW (port of `uncompress.c:77–177`)

    static func uncompressLZW(source: Data, expectedSize: Int, context: String) throws -> Data {
        guard expectedSize > 0 else {
            // The C code calls fatalError here. Swift returns empty;
            // the size check in `decompress` will raise mismatch if
            // the caller actually expected non-zero output.
            return Data()
        }

        let input = Array(source)
        let inSize = input.count

        // Code-table entries: prefix index (uint16) and append byte (uint8).
        var prefixTable = [UInt16](repeating: 0, count: 4096)
        var appendTable = [UInt8](repeating: 0, count: 4096)

        // Decode-stack scratch.
        var decodeStack = [UInt8](repeating: 0, count: 4096)
        var stackPtr = 0

        var nBits: UInt32 = 9
        var freeEntry: UInt32 = 257
        var bitpos: UInt32 = 0

        // Bit reader state (mirrors uncompress.c's static globals).
        var inOffset = 0
        var nextBit: UInt32 = 0
        var current: UInt8 = 0

        // `getByte` from the C: returns 0 if past the input.
        @inline(__always) func getByte() -> UInt8 {
            if inOffset >= inSize {
                return 0
            }
            let b = input[inOffset]
            inOffset += 1
            return b
        }

        // `getBits`: reads `n` bits, LSB-first within each byte.
        @inline(__always) func getBits(_ n: UInt32) -> UInt16 {
            if n == 0 { return 0 }
            var x: UInt32 = 0
            for i: UInt32 in 0 ..< n {
                if (current & (UInt8(1) << nextBit)) != 0 {
                    x |= (UInt32(1) << i)
                }
                nextBit += 1
                if nextBit > 7 {
                    current = getByte()
                    nextBit = 0
                }
            }
            return UInt16(truncatingIfNeeded: x)
        }

        // Prime the bit stream (matches `current = (uint8) getByte(f);`).
        current = getByte()

        var output = Data(capacity: expectedSize)

        // First code is always emitted as a literal byte.
        var oldcode = getBits(nBits)
        var lastbyte = oldcode
        output.append(UInt8(truncatingIfNeeded: oldcode))

        outer: while inOffset < inSize {

            let newcode = getBits(nBits)
            bitpos += nBits

            if newcode == 256 {
                // Reset: skip remaining bits in the current 9*nBits-aligned word.
                let nbits3 = nBits << 3
                let nskip = (nbits3 - ((bitpos &- 1) % nbits3)) - 1
                _ = getBits(nskip)
                nBits = 9
                freeEntry = 256
                bitpos = 0
                continue
            }

            var code = newcode

            // KwKwK case: code refers to a table slot we haven't filled yet.
            if UInt32(code) >= freeEntry {
                if stackPtr > 4095 {
                    break outer
                }
                decodeStack[stackPtr] = UInt8(truncatingIfNeeded: lastbyte)
                stackPtr += 1
                code = oldcode
            }

            // Walk the chain back to a literal.
            while code > 255 {
                if code > 4095 { break }
                if stackPtr >= 4096 {
                    throw ParserError(kind: .lzwStackOverflow, offset: inOffset, context: context)
                }
                decodeStack[stackPtr] = appendTable[Int(code)]
                stackPtr += 1
                code = prefixTable[Int(code)]
            }

            if stackPtr >= 4096 {
                throw ParserError(kind: .lzwStackOverflow, offset: inOffset, context: context)
            }
            decodeStack[stackPtr] = UInt8(truncatingIfNeeded: code)
            stackPtr += 1
            lastbyte = code

            // Emit in reverse — that's the decoded sequence.
            while stackPtr > 0 {
                stackPtr -= 1
                if output.count >= expectedSize {
                    return output
                }
                output.append(decodeStack[stackPtr])
            }

            // Add a new entry to the table.
            if freeEntry < 4096 {
                prefixTable[Int(freeEntry)] = oldcode
                appendTable[Int(freeEntry)] = UInt8(truncatingIfNeeded: lastbyte)
                freeEntry += 1
                let temp = UInt32(1) << nBits
                if freeEntry >= temp && nBits < 12 {
                    nBits += 1
                    bitpos = 0
                }
            }

            oldcode = newcode
        }

        // The C reference asserts exact input consumption.
        if inOffset != inSize {
            throw ParserError(
                kind: .lzwInputUnderrun(expected: inSize, consumed: inOffset),
                offset: inOffset,
                context: context
            )
        }

        return output
    }
}
