// PaletteTests.swift

import Testing
import Foundation
@testable import JohnnyResources

@Suite("Palette parsing (canonical)",
       .disabled(if: !TestResources.available, TestResources.skipMessage))
struct PaletteTests {

    @Test("Each PAL entry has exactly 256 colors and 2/4 byte unknown headers preserved")
    func structure() throws {
        let archive = try ContainerTests.archive()
        let palettes = archive.entries(of: .palette)
        #expect(!palettes.isEmpty, "no palette entries found")

        for entry in palettes {
            guard case .palette(let pal) = entry.resource else {
                Issue.record("entry '\(entry.name)' kind says .palette but cast failed")
                continue
            }
            #expect(pal.colors.count == 256, "\(entry.name): colors.count = \(pal.colors.count)")
            #expect(pal.palUnknown.count == 2)
            #expect(pal.vgaHeaderBytes.count == 4)
        }
    }

    @Test("Palette values are in VGA 6-bit range (0..63) for the canonical palette")
    func vgaSixBitRange() throws {
        let archive = try ContainerTests.archive()
        let palettes = archive.entries(of: .palette)
        for entry in palettes {
            guard case .palette(let pal) = entry.resource else { continue }
            for (i, c) in pal.colors.enumerated() {
                // The standard Sierra .PAL stores values 0..63. Surface
                // any out-of-range value so we catch encoding surprises.
                #expect(c.r <= 63, "\(entry.name) color[\(i)].r = \(c.r) > 63")
                #expect(c.g <= 63, "\(entry.name) color[\(i)].g = \(c.g) > 63")
                #expect(c.b <= 63, "\(entry.name) color[\(i)].b = \(c.b) > 63")
            }
        }
    }
}
