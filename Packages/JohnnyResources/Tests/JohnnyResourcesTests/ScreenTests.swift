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

// ScreenTests.swift

import Testing
import Foundation
@testable import JohnnyResources

@Suite("Screen parsing (canonical)",
       .disabled(if: !TestResources.available, TestResources.skipMessage))
struct ScreenTests {

    @Test("Every SCR entry parses to width × height bytes of indexed pixel data")
    func pixelBufferMatchesDimensions() throws {
        let archive = try ContainerTests.archive()
        let screens = archive.entries(of: .screen)
        #expect(!screens.isEmpty, "no screen entries found")

        for entry in screens {
            guard case .screen(let scr) = entry.resource else { continue }
            let expected = Int(scr.width) * Int(scr.height)
            #expect(
                scr.pixels.count == expected,
                "\(entry.name): pixels.count=\(scr.pixels.count) expected=\(expected) (\(scr.width)x\(scr.height))"
            )
        }
    }

    @Test("All SCRs are 640×N where N is sensible; report the actual dimensions")
    func screenDimensions() throws {
        let archive = try ContainerTests.archive()
        var dimensions: [String: (UInt16, UInt16)] = [:]
        for entry in archive.entries(of: .screen) {
            guard case .screen(let scr) = entry.resource else { continue }
            dimensions[entry.name] = (scr.width, scr.height)
            #expect(scr.width > 0 && scr.height > 0)
            // Width is consistently 640 in the canonical container.
            #expect(scr.width == 640, "\(entry.name): width=\(scr.width) ≠ 640")
            // Heights are bounded by the renderer's 480px viewport
            // (`grLoadScreen` in graphics.c:519 fatalErrors on > 480).
            #expect(scr.height <= 480, "\(entry.name): height=\(scr.height) > 480")
        }
        print("=== SCR dimensions ===")
        for (name, dim) in dimensions.sorted(by: { $0.key < $1.key }) {
            print("  \(name): \(dim.0)x\(dim.1)")
        }
        // At least one full-size 640×480 background is needed to run.
        let hasFullSize = dimensions.values.contains { $0 == (640, 480) }
        #expect(hasFullSize, "no 640×480 SCR found in canonical container")
    }

    @Test("Pixel indices are bytes (0..255) — trivial structural check")
    func pixelIndicesAreBytes() throws {
        let archive = try ContainerTests.archive()
        for entry in archive.entries(of: .screen) {
            guard case .screen(let scr) = entry.resource else { continue }
            // Every byte is by definition 0..255; this test exists to
            // surface that the buffer is uniformly sized and accessible.
            #expect(scr.pixels.count > 0)
        }
    }
}
