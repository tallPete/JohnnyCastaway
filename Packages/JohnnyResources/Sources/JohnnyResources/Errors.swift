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

// Errors.swift
//
// All errors thrown by the parser surface through `ParserError`. Every
// instance carries the byte offset where the parse failed plus a
// breadcrumb describing what was being parsed at the time, so a stack
// trace is rarely necessary to diagnose a malformed input.

import Foundation

public struct ParserError: Error, CustomStringConvertible, Sendable {

    public enum Kind: Sendable, Equatable {

        /// Tried to read `needed` bytes but only `available` remain.
        case truncated(needed: Int, available: Int)

        /// A 4-byte ASCII section magic ("PAL:", "BMP:" etc.) didn't match.
        case unexpectedMagic(expected: String, got: String)

        /// Container entry's filename extension is unrecognised. The
        /// canonical file has one of these (`FILES.VIN`); other ports
        /// also surface it. We preserve it as `.unknown` rather than
        /// throwing, but if a strict-parse pass is requested this kind
        /// is what fires.
        case unknownResourceExtension(String)

        /// Compression-method byte was not 1 (RLE) or 2 (LZW).
        case unsupportedCompression(method: UInt8)

        /// Decompressor produced a different number of bytes than the
        /// container header declared.
        case decompressedSizeMismatch(expected: Int, got: Int)

        /// LZW decoder's decode-stack exceeded its 4096-byte limit.
        case lzwStackOverflow

        /// LZW decoder consumed a number of input bytes other than the
        /// declared compressed-payload size.
        case lzwInputUnderrun(expected: Int, consumed: Int)

        /// RLE decoder consumed a number of input bytes other than the
        /// declared compressed-payload size.
        case rleInputUnderrun(expected: Int, consumed: Int)

        /// A filename or magic string contained non-ASCII bytes.
        case malformedString
    }

    public let kind: Kind

    /// Byte offset within the input data where the error was detected.
    public let offset: Int

    /// Free-text breadcrumb e.g. "BMP section of BACKGRND.BMP at MAP entry 12".
    public let context: String

    public init(kind: Kind, offset: Int, context: String) {
        self.kind = kind
        self.offset = offset
        self.context = context
    }

    public var description: String {
        "ParserError(\(context), offset=\(offset)): \(kind)"
    }
}
