// BinaryReaderTests.swift

import Testing
import Foundation
@testable import JohnnyResources

@Suite("BinaryReader")
struct BinaryReaderTests {

    @Test("readUInt8 advances cursor by 1")
    func readUInt8Advances() throws {
        var r = BinaryReader(data: Data([0x12, 0x34, 0x56]), context: "test")
        #expect(try r.readUInt8() == 0x12)
        #expect(r.cursor == 1)
        #expect(try r.readUInt8() == 0x34)
        #expect(r.cursor == 2)
    }

    @Test("readUInt16LE decodes little-endian word")
    func readUInt16LE() throws {
        var r = BinaryReader(data: Data([0x34, 0x12, 0xCD, 0xAB]), context: "test")
        #expect(try r.readUInt16LE() == 0x1234)
        #expect(try r.readUInt16LE() == 0xABCD)
    }

    @Test("readUInt32LE decodes little-endian dword")
    func readUInt32LE() throws {
        var r = BinaryReader(data: Data([0x78, 0x56, 0x34, 0x12]), context: "test")
        #expect(try r.readUInt32LE() == 0x12345678)
    }

    @Test("readBytes returns slice and advances cursor")
    func readBytesSlices() throws {
        var r = BinaryReader(data: Data([1, 2, 3, 4, 5]), context: "test")
        let slice = try r.readBytes(3)
        #expect(Array(slice) == [1, 2, 3])
        #expect(r.cursor == 3)
    }

    @Test("readFixedWidthString stops at null but consumes full window")
    func readFixedWidthStopsAtNull() throws {
        var r = BinaryReader(data: Data("HI\0XYZ".utf8 + [0]), context: "test")
        let s = try r.readFixedWidthString(length: 6)
        #expect(s == "HI")
        // All 6 bytes consumed regardless of where the null was.
        #expect(r.cursor == 6)
    }

    @Test("readFixedWidthString returns full string when no null present")
    func readFixedWidthNoNull() throws {
        var r = BinaryReader(data: Data("ABCDE".utf8), context: "test")
        let s = try r.readFixedWidthString(length: 5)
        #expect(s == "ABCDE")
    }

    @Test("readNullTerminatedString stops AT the null and consumes only that far")
    func readNullTerminatedShort() throws {
        // "HI\0XYZ" — should read "HI" and consume 3 bytes (H, I, \0).
        var r = BinaryReader(data: Data("HI\0XYZ".utf8), context: "test")
        let s = try r.readNullTerminatedString(maxLength: 40)
        #expect(s == "HI")
        #expect(r.cursor == 3)
    }

    @Test("readNullTerminatedString respects maxLength when no null is present")
    func readNullTerminatedTruncatesAtMaxLength() throws {
        // 5-char string with no null; maxLength of 5 -> consume all 5.
        var r = BinaryReader(data: Data("ABCDExtra".utf8), context: "test")
        let s = try r.readNullTerminatedString(maxLength: 5)
        #expect(s == "ABCDE")
        #expect(r.cursor == 5)
    }

    @Test("readNullTerminatedString returns ISO-Latin-1 for high bytes (≥ 0x80)")
    func readNullTerminatedHighBytes() throws {
        // 0xFF (ÿ in ISO-Latin-1) followed by null.
        var r = BinaryReader(data: Data([0xFF, 0x00, 0x42]), context: "test")
        let s = try r.readNullTerminatedString(maxLength: 10)
        #expect(s == "ÿ")
        #expect(r.cursor == 2)
    }

    @Test("expectMagic accepts matching string and advances")
    func expectMagicMatches() throws {
        var r = BinaryReader(data: Data("PAL:trail".utf8), context: "test")
        try r.expectMagic("PAL:")
        #expect(r.cursor == 4)
    }

    @Test("expectMagic throws unexpectedMagic with offset on mismatch")
    func expectMagicMismatch() {
        var r = BinaryReader(data: Data("XXX:trail".utf8), context: "test")
        do {
            try r.expectMagic("PAL:")
            Issue.record("expected throw")
        } catch let e as ParserError {
            switch e.kind {
            case .unexpectedMagic(let expected, let got):
                #expect(expected == "PAL:")
                #expect(got == "XXX:")
                #expect(e.offset == 0)
            default:
                Issue.record("wrong error kind: \(e.kind)")
            }
        } catch {
            Issue.record("non-ParserError thrown")
        }
    }

    @Test("readUInt32LE throws truncated when not enough bytes remain")
    func readUInt32Truncated() {
        var r = BinaryReader(data: Data([0x01, 0x02]), context: "test")
        do {
            _ = try r.readUInt32LE()
            Issue.record("expected throw")
        } catch let e as ParserError {
            switch e.kind {
            case .truncated(let needed, let available):
                #expect(needed == 4)
                #expect(available == 2)
            default:
                Issue.record("wrong error kind: \(e.kind)")
            }
        } catch {
            Issue.record("non-ParserError thrown")
        }
    }

    @Test("seek moves cursor to absolute offset")
    func seekToAbsolute() throws {
        var r = BinaryReader(data: Data([1, 2, 3, 4, 5]), context: "test")
        try r.seek(to: 3)
        #expect(try r.readUInt8() == 4)
    }
}
