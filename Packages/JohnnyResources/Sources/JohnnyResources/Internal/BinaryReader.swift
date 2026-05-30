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

// BinaryReader.swift
//
// Bounds-checked little-endian binary reader. All multi-byte fields in
// the Sierra resource format are little-endian.
//
// The reader is a value type with an explicit `cursor`; callers thread
// it through `inout` parameters or hold it locally. This keeps the
// per-frame interpreter (Phase 2) able to fork-and-resume from a saved
// cursor without object allocation.

import Foundation

struct BinaryReader {

    let data: Data
    let baseOffset: Int
    var cursor: Int
    var context: String

    init(data: Data, context: String, baseOffset: Int = 0) {
        self.data = data
        self.baseOffset = baseOffset
        self.cursor = baseOffset
        self.context = context
    }

    var remaining: Int { data.count - cursor }
    var isAtEnd: Bool { cursor >= data.count }

    /// Move the cursor to an absolute offset within `data`.
    mutating func seek(to absoluteOffset: Int) throws {
        guard absoluteOffset >= 0, absoluteOffset <= data.count else {
            throw ParserError(
                kind: .truncated(needed: absoluteOffset, available: data.count),
                offset: cursor,
                context: context
            )
        }
        cursor = absoluteOffset
    }

    @inline(__always)
    mutating func readUInt8() throws -> UInt8 {
        try ensureAvailable(1)
        let b = data[cursor]
        cursor += 1
        return b
    }

    @inline(__always)
    mutating func readUInt16LE() throws -> UInt16 {
        try ensureAvailable(2)
        let lo = UInt16(data[cursor])
        let hi = UInt16(data[cursor + 1])
        cursor += 2
        return (hi << 8) | lo
    }

    @inline(__always)
    mutating func readUInt32LE() throws -> UInt32 {
        try ensureAvailable(4)
        let b0 = UInt32(data[cursor])
        let b1 = UInt32(data[cursor + 1])
        let b2 = UInt32(data[cursor + 2])
        let b3 = UInt32(data[cursor + 3])
        cursor += 4
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }

    /// Read `n` bytes as a sub-`Data` (zero-copy slice into the input).
    mutating func readBytes(_ n: Int) throws -> Data {
        try ensureAvailable(n)
        let slice = data[cursor ..< cursor + n]
        cursor += n
        return slice
    }

    /// Skip `n` bytes without reading them.
    mutating func skip(_ n: Int) throws {
        try ensureAvailable(n)
        cursor += n
    }

    /// Read exactly `n` bytes and decode the prefix up to the first
    /// null terminator as a string. Always consumes `n` bytes, even
    /// when the null appears earlier — used for fixed-width name
    /// fields (the 13-byte resource name, the 13-byte map filename).
    ///
    /// Uses ISO Latin-1 (not ASCII) because the original 1992 game
    /// shipped Western-European-extended bytes ≥ 0x80 in some
    /// strings; ISO Latin-1 decodes any byte 0..255 losslessly.
    mutating func readFixedWidthString(length n: Int) throws -> String {
        let bytes = try readBytes(n)
        let nullIndex = bytes.firstIndex(of: 0x00) ?? bytes.endIndex
        let upToNull = bytes[bytes.startIndex ..< nullIndex]
        return String(data: upToNull, encoding: .isoLatin1) ?? ""
    }

    /// Read bytes up to AND INCLUDING the first null terminator, but
    /// no more than `maxLength` bytes total. Returns the string of
    /// bytes BEFORE the null. The cursor advances by the number of
    /// bytes actually consumed (which may be less than `maxLength`).
    ///
    /// Mirrors C's `getString(f, maxlen)` in `utils.c:118`. Used for
    /// variable-length name and description fields in TTM/ADS
    /// resources (declared as `getString(f, 40)`).
    mutating func readNullTerminatedString(maxLength: Int) throws -> String {
        var stringBytes = [UInt8]()
        stringBytes.reserveCapacity(maxLength)
        var consumed = 0
        while consumed < maxLength {
            let b = try readUInt8()
            consumed += 1
            if b == 0 { break }
            stringBytes.append(b)
        }
        return String(data: Data(stringBytes), encoding: .isoLatin1) ?? ""
    }

    /// Read 4 ASCII bytes and assert they equal `expected`. Throws
    /// `unexpectedMagic` with the offset where the magic started.
    mutating func expectMagic(_ expected: String) throws {
        let startCursor = cursor
        let bytes = try readBytes(expected.utf8.count)
        if !bytes.elementsEqual(expected.utf8) {
            let got = String(data: bytes, encoding: .ascii) ?? "<non-ascii>"
            throw ParserError(
                kind: .unexpectedMagic(expected: expected, got: got),
                offset: startCursor,
                context: context
            )
        }
    }

    @inline(__always)
    private func ensureAvailable(_ n: Int) throws {
        guard remaining >= n else {
            throw ParserError(
                kind: .truncated(needed: n, available: remaining),
                offset: cursor,
                context: context
            )
        }
    }
}
