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

// ADSScriptParser.swift
//
// Translated from `parseAdsResource` in `resource.c:54–131`.

import Foundation

enum ADSScriptParser {

    static func parse(_ reader: inout BinaryReader) throws -> ADSScript {
        try reader.expectMagic("VER:")
        let versionSize = try reader.readUInt32LE()
        let version = try reader.readBytes(5)

        try reader.expectMagic("ADS:")
        let ads0 = try reader.readUInt8()
        let ads1 = try reader.readUInt8()
        let ads2 = try reader.readUInt8()
        let ads3 = try reader.readUInt8()

        try reader.expectMagic("RES:")
        let resSize = try reader.readUInt32LE()
        let numRes = try reader.readUInt16LE()

        var refs: [ADSScript.ResourceReference] = []
        refs.reserveCapacity(Int(numRes))
        for _ in 0 ..< numRes {
            let id = try reader.readUInt16LE()
            let name = try reader.readNullTerminatedString(maxLength: 40)
            refs.append(.init(id: id, name: name))
        }

        try reader.expectMagic("SCR:")
        let (method, bytecode) = try reader.readCompressedPayload()

        try reader.expectMagic("TAG:")
        _ = try reader.readUInt32LE()  // tagSize, declared but unused
        let numTags = try reader.readUInt16LE()

        var tags: [ADSScript.Tag] = []
        tags.reserveCapacity(Int(numTags))
        for _ in 0 ..< numTags {
            let id = try reader.readUInt16LE()
            let description = try reader.readNullTerminatedString(maxLength: 40)
            tags.append(.init(id: id, description: description))
        }

        return ADSScript(
            version: version,
            versionSize: versionSize,
            adsUnknown: [ads0, ads1, ads2, ads3],
            resSize: resSize,
            referencedResources: refs,
            compression: method,
            bytecode: bytecode,
            tags: tags
        )
    }
}
