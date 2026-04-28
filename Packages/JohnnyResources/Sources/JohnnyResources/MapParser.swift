// MapParser.swift
//
// Parses RESOURCE.MAP. Each entry yields a (length, offset) pair into
// the companion RESOURCE.001 container; the resource name lives at the
// start of each container entry, not in the map.
//
// Translated from `parseMapFile` in `resource.c:342–370`.

import Foundation

/// Top-level result of parsing RESOURCE.MAP.
public struct ResourceMap: Sendable, Equatable {

    public struct Entry: Sendable, Equatable {
        /// First uint32 of the entry record. jc_reborn names this
        /// `length` but the field is read and immediately discarded
        /// — never consulted anywhere. Its values look like packed
        /// data (likely a checksum, hash, or fragment of a
        /// type-encoding scheme) and bear no relationship to the
        /// resource's actual byte length. Preserved for round-trip
        /// fidelity; no parser logic depends on it.
        public let unknownField: UInt32

        /// Absolute byte offset into RESOURCE.001 where this entry begins.
        public let offset: UInt32

        public init(unknownField: UInt32, offset: UInt32) {
            self.unknownField = unknownField
            self.offset = offset
        }
    }

    /// Six unknown bytes from the file header. `unknownBytes[3]` may be
    /// "number of resource files in this index" per jc_reborn's TODO,
    /// but the value is unused. Preserved for completeness.
    public let unknownBytes: [UInt8]

    /// Filename of the companion resource container (e.g. "RESOURCE.001").
    public let containerFilename: String

    /// Per-entry (length, offset) records.
    public let entries: [Entry]

    public init(
        unknownBytes: [UInt8],
        containerFilename: String,
        entries: [Entry]
    ) {
        precondition(unknownBytes.count == 6, "MAP unknown bytes must be 6")
        self.unknownBytes = unknownBytes
        self.containerFilename = containerFilename
        self.entries = entries
    }
}

public enum MapParser {

    /// Parse RESOURCE.MAP from raw bytes.
    public static func parse(_ data: Data) throws -> ResourceMap {
        var r = BinaryReader(data: data, context: "RESOURCE.MAP")

        let u1 = try r.readUInt8()
        let u2 = try r.readUInt8()
        let u3 = try r.readUInt8()
        let u4 = try r.readUInt8()
        let u5 = try r.readUInt8()
        let u6 = try r.readUInt8()

        let containerName = try r.readFixedWidthString(length: 13)
        let numEntries = try r.readUInt16LE()

        var entries: [ResourceMap.Entry] = []
        entries.reserveCapacity(Int(numEntries))
        for _ in 0 ..< numEntries {
            let unknown = try r.readUInt32LE()
            let offset = try r.readUInt32LE()
            entries.append(.init(unknownField: unknown, offset: offset))
        }

        return ResourceMap(
            unknownBytes: [u1, u2, u3, u4, u5, u6],
            containerFilename: containerName,
            entries: entries
        )
    }
}
