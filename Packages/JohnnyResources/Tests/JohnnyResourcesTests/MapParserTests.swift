// MapParserTests.swift
//
// Tests against the canonical RESOURCE.MAP (MD5
// 374e6d05c5e0acd88fb5af748948c899, 1461 bytes).

import Testing
import Foundation
@testable import JohnnyResources

@Suite("MapParser (canonical RESOURCE.MAP)",
       .disabled(if: !TestResources.available, TestResources.skipMessage))
struct MapParserTests {

    @Test("Canonical file has the expected MD5")
    func canonicalFileMD5() throws {
        let data = try #require(TestResources.mapData)
        #expect(data.count == 1461)
        #expect(MD5Hash.hex(data) == "374e6d05c5e0acd88fb5af748948c899")
    }

    @Test("Parses to exactly 180 entries")
    func entryCount() throws {
        let data = try #require(TestResources.mapData)
        let map = try MapParser.parse(data)
        #expect(map.entries.count == 180)
    }

    @Test("Container filename is RESOURCE.001")
    func containerFilename() throws {
        let data = try #require(TestResources.mapData)
        let map = try MapParser.parse(data)
        #expect(map.containerFilename == "RESOURCE.001")
    }

    @Test("Every entry's offset is within the canonical container size (1,175,645)")
    func offsetsWithinContainer() throws {
        let data = try #require(TestResources.mapData)
        let map = try MapParser.parse(data)
        let containerSize: UInt32 = 1_175_645
        for (i, entry) in map.entries.enumerated() {
            #expect(
                entry.offset < containerSize,
                "entry \(i) offset \(entry.offset) >= container size"
            )
        }
    }

    @Test("Offsets are unique (no two entries point at the same byte)")
    func offsetsUnique() throws {
        let data = try #require(TestResources.mapData)
        let map = try MapParser.parse(data)
        let offsets = map.entries.map(\.offset)
        let unique = Set(offsets)
        #expect(offsets.count == unique.count, "duplicate offsets in map")
    }

    @Test("Header unknown bytes preserved (6 bytes)")
    func headerBytesPreserved() throws {
        let data = try #require(TestResources.mapData)
        let map = try MapParser.parse(data)
        #expect(map.unknownBytes.count == 6)
    }
}
