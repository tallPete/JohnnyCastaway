// TTMScriptParser.swift
//
// Translated from `parseTtmResource` in `resource.c:269–339`.

import Foundation

enum TTMScriptParser {

    static func parse(_ reader: inout BinaryReader) throws -> TTMScript {
        try reader.expectMagic("VER:")
        let versionSize = try reader.readUInt32LE()
        let version = try reader.readBytes(5)

        try reader.expectMagic("PAG:")
        let numPages = try reader.readUInt32LE()
        let pagU1 = try reader.readUInt8()
        let pagU2 = try reader.readUInt8()

        try reader.expectMagic("TT3:")
        let (method, bytecode) = try reader.readCompressedPayload()

        try reader.expectMagic("TTI:")
        let tti0 = try reader.readUInt8()
        let tti1 = try reader.readUInt8()
        let tti2 = try reader.readUInt8()
        let tti3 = try reader.readUInt8()

        try reader.expectMagic("TAG:")
        _ = try reader.readUInt32LE()  // tagSize, declared but unused
        let numTags = try reader.readUInt16LE()

        var tags: [TTMScript.Tag] = []
        tags.reserveCapacity(Int(numTags))
        for _ in 0 ..< numTags {
            let id = try reader.readUInt16LE()
            let description = try reader.readNullTerminatedString(maxLength: 40)
            tags.append(.init(id: id, description: description))
        }

        return TTMScript(
            version: version,
            versionSize: versionSize,
            numPages: numPages,
            pagUnknown: [pagU1, pagU2],
            compression: method,
            bytecode: bytecode,
            ttiUnknown: [tti0, tti1, tti2, tti3],
            tags: tags
        )
    }
}
