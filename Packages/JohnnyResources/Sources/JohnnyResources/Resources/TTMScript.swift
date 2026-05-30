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

// TTMScript.swift
//
// Per-scene animation script (.TTM). The `bytecode` field is the
// uncompressed opcode stream for the Phase 2 interpreter; this
// parser stays out of the interpretation business and just hands the
// bytes back.
//
// Translated from `parseTtmResource` in `resource.c:269–339`.

import Foundation

public struct TTMScript: Sendable, Equatable {

    /// 5-byte version string declared after the `VER:` magic.
    public let version: Data

    /// Declared version-section size (uint32). Should equal 5.
    public let versionSize: UInt32

    /// Number of pages (uint32). Semantics: appears unused by interpreters.
    public let numPages: UInt32

    /// Two bytes following `numPages`, semantics unknown.
    public let pagUnknown: [UInt8]

    public let compression: CompressionMethod

    /// Uncompressed opcode stream, ready for the Phase 2 TTM interpreter.
    public let bytecode: Data

    /// Four bytes following the `TTI:` magic, semantics unknown.
    public let ttiUnknown: [UInt8]

    public struct Tag: Sendable, Equatable {
        public let id: UInt16
        public let description: String

        public init(id: UInt16, description: String) {
            self.id = id
            self.description = description
        }
    }

    /// Tag table mapping IDs to scene-name strings (40-byte fields).
    public let tags: [Tag]

    public init(
        version: Data,
        versionSize: UInt32,
        numPages: UInt32,
        pagUnknown: [UInt8],
        compression: CompressionMethod,
        bytecode: Data,
        ttiUnknown: [UInt8],
        tags: [Tag]
    ) {
        precondition(pagUnknown.count == 2, "TTM PAG unknown bytes must be 2")
        precondition(ttiUnknown.count == 4, "TTM TTI unknown bytes must be 4")
        self.version = version
        self.versionSize = versionSize
        self.numPages = numPages
        self.pagUnknown = pagUnknown
        self.compression = compression
        self.bytecode = bytecode
        self.ttiUnknown = ttiUnknown
        self.tags = tags
    }
}
