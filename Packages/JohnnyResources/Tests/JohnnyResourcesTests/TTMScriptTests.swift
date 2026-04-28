// TTMScriptTests.swift

import Testing
import Foundation
@testable import JohnnyResources

@Suite("TTMScript parsing (canonical)",
       .disabled(if: !TestResources.available, TestResources.skipMessage))
struct TTMScriptTests {

    @Test("Every TTM has 5-byte version, non-empty bytecode, and a tag table")
    func structure() throws {
        let archive = try ContainerTests.archive()
        let ttms = archive.entries(of: .ttmScript)
        #expect(!ttms.isEmpty, "no TTM entries found")

        for entry in ttms {
            guard case .ttmScript(let s) = entry.resource else { continue }
            #expect(s.version.count == 5, "\(entry.name) version length")
            #expect(s.versionSize == 5, "\(entry.name) versionSize=\(s.versionSize)")
            #expect(s.bytecode.count > 0, "\(entry.name) empty bytecode")
            #expect(s.pagUnknown.count == 2)
            #expect(s.ttiUnknown.count == 4)
            // tags can be empty but the count should be self-consistent
            for tag in s.tags {
                #expect(tag.description.count <= 39,
                        "\(entry.name) tag id=\(tag.id) description too long: \(tag.description.count)")
            }
        }
    }

    @Test("Bytecode length is even (opcodes are uint16-aligned)")
    func bytecodeIsWordAligned() throws {
        let archive = try ContainerTests.archive()
        for entry in archive.entries(of: .ttmScript) {
            guard case .ttmScript(let s) = entry.resource else { continue }
            // TTM opcodes are 16-bit. Length is permitted to be odd
            // because of variable-length string args padded to 16-bit
            // boundaries — surface odd lengths but don't fail.
            if s.bytecode.count % 2 != 0 {
                Issue.record("\(entry.name) bytecode length \(s.bytecode.count) is odd; review interpreter handling")
            }
        }
    }
}
