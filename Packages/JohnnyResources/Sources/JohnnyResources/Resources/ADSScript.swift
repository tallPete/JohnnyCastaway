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

// ADSScript.swift
//
// Scene-orchestration script (.ADS). Holds:
//   * a table of TTM resources this script will invoke (`referencedResources`)
//   * the uncompressed scene-orchestration `bytecode` for the Phase 2 ADS interpreter
//   * a tag table mapping scene-tag IDs to descriptive strings
//
// Translated from `parseAdsResource` in `resource.c:54–131`.

import Foundation

public struct ADSScript: Sendable, Equatable {

    /// 5-byte version string declared after the `VER:` magic.
    public let version: Data

    /// Declared version-section size (uint32). Should equal 5.
    public let versionSize: UInt32

    /// Four bytes following the `ADS:` magic, semantics unknown.
    public let adsUnknown: [UInt8]

    public struct ResourceReference: Sendable, Equatable {
        /// Slot index used by ADS opcodes to refer to this resource.
        public let id: UInt16
        /// Resource name e.g. "JOHNNY.TTM".
        public let name: String

        public init(id: UInt16, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Declared RES-section size (uint32).
    public let resSize: UInt32

    /// TTM resources referenced by this ADS script.
    public let referencedResources: [ResourceReference]

    public let compression: CompressionMethod

    /// Uncompressed opcode stream for the Phase 2 ADS interpreter.
    public let bytecode: Data

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
        adsUnknown: [UInt8],
        resSize: UInt32,
        referencedResources: [ResourceReference],
        compression: CompressionMethod,
        bytecode: Data,
        tags: [Tag]
    ) {
        precondition(adsUnknown.count == 4, "ADS unknown bytes must be 4")
        self.version = version
        self.versionSize = versionSize
        self.adsUnknown = adsUnknown
        self.resSize = resSize
        self.referencedResources = referencedResources
        self.compression = compression
        self.bytecode = bytecode
        self.tags = tags
    }
}
