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

// RLEDecoderTests.swift
//
// RLE format (port of `uncompress.c:180–215`):
//   control byte: high bit set => run of (control & 0x7F) bytes of the
//   next byte; high bit clear => literal copy of `control` bytes.

import Testing
import Foundation
@testable import JohnnyResources

@Suite("RLE decoder")
struct RLEDecoderTests {

    @Test("Pure literal block decodes verbatim")
    func pureLiteral() throws {
        // control = 0x05 (literal, 5 bytes), payload = ABCDE
        let input = Data([0x05, 0x41, 0x42, 0x43, 0x44, 0x45])
        let out = try Decompressor.uncompressRLE(source: input, expectedSize: 5, context: "test")
        #expect(Array(out) == [0x41, 0x42, 0x43, 0x44, 0x45])
    }

    @Test("Pure run block decodes to repeated byte")
    func pureRun() throws {
        // control = 0x88 (run of 8), value = 0xFF -> 8 × 0xFF
        let input = Data([0x88, 0xFF])
        let out = try Decompressor.uncompressRLE(source: input, expectedSize: 8, context: "test")
        #expect(out.count == 8)
        #expect(out.allSatisfy { $0 == 0xFF })
    }

    @Test("Mixed literal and run blocks reassemble correctly")
    func mixed() throws {
        // 3 literals 'A' 'B' 'C', then run of 4 × 'Z', then 2 literals 'X' 'Y'
        let input = Data([
            0x03, 0x41, 0x42, 0x43,   // literal 'ABC'
            0x84, 0x5A,               // run of 4 × 'Z'
            0x02, 0x58, 0x59          // literal 'XY'
        ])
        let out = try Decompressor.uncompressRLE(source: input, expectedSize: 9, context: "test")
        #expect(Array(out) == [0x41, 0x42, 0x43, 0x5A, 0x5A, 0x5A, 0x5A, 0x58, 0x59])
    }

    @Test("Maximal run length 0x7F yields 127 bytes")
    func maxRun() throws {
        let input = Data([0xFF, 0x42])  // 0x7F == 127, with high bit set
        let out = try Decompressor.uncompressRLE(source: input, expectedSize: 127, context: "test")
        #expect(out.count == 127)
        #expect(out.allSatisfy { $0 == 0x42 })
    }

    @Test("Maximal literal length 0x7F yields 127 bytes")
    func maxLiteral() throws {
        var input = Data([0x7F])
        let payload = (0..<127).map { UInt8($0) }
        input.append(contentsOf: payload)
        let out = try Decompressor.uncompressRLE(source: input, expectedSize: 127, context: "test")
        #expect(Array(out) == payload)
    }

    @Test("Decoder throws when input runs out mid-control")
    func truncatedAtControl() {
        // Promise 5 bytes of output but supply nothing.
        let input = Data()
        do {
            _ = try Decompressor.uncompressRLE(source: input, expectedSize: 5, context: "test")
            Issue.record("expected throw")
        } catch is ParserError {
            // expected
        } catch {
            Issue.record("non-ParserError thrown")
        }
    }
}
