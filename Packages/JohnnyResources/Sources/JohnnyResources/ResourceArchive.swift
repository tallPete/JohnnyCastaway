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

// ResourceArchive.swift
//
// The top-level public type. Parses a (RESOURCE.MAP, RESOURCE.001) pair
// of `Data` blobs and yields a typed catalogue of every entry.
//
// Translated from `parseResourceFile` in `resource.c:373–436`.

import Foundation

public struct ResourceArchive: Sendable {

    /// One entry in the container, located via the map.
    public struct Entry: Sendable {
        /// 13-byte resource name as stored at the start of the
        /// container entry, e.g. "ACTIVITY.ADS".
        public let name: String

        /// First uint32 of the corresponding RESOURCE.MAP record.
        /// Semantics unclear — read but not used by jc_reborn. See
        /// `ResourceMap.Entry.unknownField`.
        public let mapUnknownField: UInt32

        /// Absolute byte offset of this entry within the container.
        public let containerOffset: UInt32

        /// uint32 read inside the container at `offset + 13`. The C
        /// reference calls this `resSize` and reads it into a struct
        /// field, but it isn't consulted anywhere either. Likely a
        /// declared section size; preserved without asserting.
        public let containerDeclaredSize: UInt32

        /// The parsed payload.
        public let resource: Resource

        public init(
            name: String,
            mapUnknownField: UInt32,
            containerOffset: UInt32,
            containerDeclaredSize: UInt32,
            resource: Resource
        ) {
            self.name = name
            self.mapUnknownField = mapUnknownField
            self.containerOffset = containerOffset
            self.containerDeclaredSize = containerDeclaredSize
            self.resource = resource
        }
    }

    public let map: ResourceMap
    public let entries: [Entry]

    /// Lookup by uppercased filename.
    public func entry(named name: String) -> Entry? {
        let needle = name.uppercased()
        return entries.first { $0.name.uppercased() == needle }
    }

    public subscript(name: String) -> Resource? {
        entry(named: name)?.resource
    }

    /// Convenience: all entries of a given kind.
    public func entries(of kind: ResourceKind) -> [Entry] {
        entries.filter { $0.resource.kind == kind }
    }

    public init(map: ResourceMap, entries: [Entry]) {
        self.map = map
        self.entries = entries
    }
}

extension ResourceArchive {

    /// Parse a complete archive from in-memory map and container bytes.
    /// The library does no file I/O; callers load the bytes themselves.
    public static func parse(map mapData: Data, container containerData: Data) throws -> ResourceArchive {
        let map = try MapParser.parse(mapData)

        var parsed: [Entry] = []
        parsed.reserveCapacity(map.entries.count)

        for (index, mapEntry) in map.entries.enumerated() {
            // Each entry begins with a 13-byte resource name + uint32 size.
            var reader = BinaryReader(
                data: containerData,
                context: "RESOURCE.001 entry #\(index)",
                baseOffset: Int(mapEntry.offset)
            )

            let resName = try reader.readFixedWidthString(length: 13)
            // Re-tag the reader's context with the resolved name now
            // that we have it.
            reader.context = "\(resName) (entry #\(index) @ offset \(mapEntry.offset))"

            let containerSize = try reader.readUInt32LE()
            let resource = try parseResource(named: resName, reader: &reader)

            parsed.append(.init(
                name: resName,
                mapUnknownField: mapEntry.unknownField,
                containerOffset: mapEntry.offset,
                containerDeclaredSize: containerSize,
                resource: resource
            ))
        }

        return ResourceArchive(map: map, entries: parsed)
    }

    private static func parseResource(named name: String, reader: inout BinaryReader) throws -> Resource {
        // Take the last 4 chars of the filename as the extension.
        let ext: String
        if name.count >= 4 {
            ext = String(name.suffix(4))
        } else {
            ext = ""
        }

        guard let kind = ResourceKind.fromExtension(ext) else {
            // Preserve unrecognised entries (e.g. FILES.VIN) as raw bytes.
            // We don't know the section size, so we save everything from
            // the cursor to end-of-data; the caller can re-clip if needed.
            let raw = reader.data.subdata(in: reader.cursor ..< reader.data.count)
            return .unrecognised(extension: ext, rawData: raw)
        }

        switch kind {
        case .palette:
            return .palette(try PaletteParser.parse(&reader))
        case .screen:
            return .screen(try ScreenParser.parse(&reader))
        case .bitmap:
            return .bitmap(try BitmapParser.parse(&reader))
        case .ttmScript:
            return .ttmScript(try TTMScriptParser.parse(&reader))
        case .adsScript:
            return .adsScript(try ADSScriptParser.parse(&reader))
        case .unrecognised:
            // Should not reach here given the guard above; defensive.
            let raw = reader.data.subdata(in: reader.cursor ..< reader.data.count)
            return .unrecognised(extension: ext, rawData: raw)
        }
    }
}
