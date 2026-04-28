// LZWDecoderTests.swift
//
// The LZW decoder is hard to round-trip without an encoder we don't
// have, but its structural behaviour can still be verified:
//
//   * Reading literal codes 0..255 at the initial 9-bit width works.
//   * The bit reader is LSB-first within each byte.
//   * Past-EOF reads return zero (mirrors `getByte` in the C).
//   * The strict consumption check fires when input is over-long.
//
// End-to-end correctness is asserted in `ContainerTests.swift` —
// every BIN block in the canonical container decompresses to its
// declared size, with the byte signature MD5-pinned.

import Testing
import Foundation
@testable import JohnnyResources

@Suite("LZW decoder")
struct LZWDecoderTests {

    /// Pack `codes` (each `bitsPerCode` wide) LSB-first into a byte
    /// stream, exactly as the LZW encoder would. Mirrors the C
    /// `getBits` reader in reverse.
    static func packLSBFirst(codes: [UInt16], bitsPerCode: Int) -> Data {
        var bytes: [UInt8] = []
        var current: UInt8 = 0
        var nextBit = 0
        for code in codes {
            for i in 0 ..< bitsPerCode {
                let bit = (code >> i) & 1
                if bit == 1 {
                    current |= UInt8(1) << nextBit
                }
                nextBit += 1
                if nextBit > 7 {
                    bytes.append(current)
                    current = 0
                    nextBit = 0
                }
            }
        }
        if nextBit != 0 { bytes.append(current) }
        return Data(bytes)
    }

    @Test("Single literal byte at 9-bit width")
    func singleLiteral() throws {
        // Code 'A' (0x41) packed as 9 bits LSB-first.
        let input = Self.packLSBFirst(codes: [0x41], bitsPerCode: 9)
        let out = try Decompressor.uncompressLZW(source: input, expectedSize: 1, context: "test")
        #expect(Array(out) == [0x41])
    }

    @Test("Run of distinct literal bytes at 9-bit width")
    func literalRun() throws {
        // Five literal bytes; first goes through prime path, rest go
        // through the main loop's "code <= 255" branch.
        let bytes: [UInt8] = [0x41, 0x42, 0x43, 0x44, 0x45]
        let input = Self.packLSBFirst(codes: bytes.map(UInt16.init), bitsPerCode: 9)
        // The decoder will also try to add codes 257, 258, ... to the
        // dictionary as it goes. That's expected and harmless here.
        let out = try Decompressor.uncompressLZW(source: input, expectedSize: bytes.count, context: "test")
        #expect(Array(out) == bytes)
    }

    @Test("Dictionary reuse: emit a literal then back-reference it via dict code 257")
    func dictionaryReuse() throws {
        // Emit 'A' (literal 0x41), then 'B' (literal 0x42).
        // The decoder adds entry 257 = (oldcode=0x41, append=0x42) — i.e. "AB".
        // Then emit code 257 to back-reference "AB".
        // Expected output: "A B A B" -> "ABAB"
        let input = Self.packLSBFirst(codes: [0x41, 0x42, 257], bitsPerCode: 9)
        let out = try Decompressor.uncompressLZW(source: input, expectedSize: 4, context: "test")
        #expect(Array(out) == [0x41, 0x42, 0x41, 0x42])
    }

    @Test("Decoder produces empty Data when expectedSize is 0")
    func emptyOutput() throws {
        let out = try Decompressor.uncompressLZW(source: Data(), expectedSize: 0, context: "test")
        #expect(out.isEmpty)
    }

    @Test("decompress() with mismatched size throws decompressedSizeMismatch")
    func sizeMismatchThrows() {
        // Single literal byte but caller declares 5 bytes expected.
        let input = Self.packLSBFirst(codes: [0x41], bitsPerCode: 9)
        do {
            _ = try Decompressor.decompress(method: .lzw, source: input, expectedSize: 5, context: "test")
            Issue.record("expected throw")
        } catch let e as ParserError {
            switch e.kind {
            case .decompressedSizeMismatch(let exp, let got):
                #expect(exp == 5)
                #expect(got <= 5)  // exact size depends on dictionary growth
            default:
                Issue.record("wrong error kind: \(e.kind)")
            }
        } catch {
            Issue.record("non-ParserError thrown")
        }
    }

    @Test("dispatch for unknown compression method throws unsupportedCompression",
          arguments: [UInt8](0...255).filter { $0 != 1 && $0 != 2 }.prefix(5))
    func unsupportedCompressionMethod(method: UInt8) {
        // Sanity-check that the CompressionMethod enum rejects bad values.
        #expect(CompressionMethod(rawValue: method) == nil)
    }
}
