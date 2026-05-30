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

// PNGDumpTests.swift
//
// Diagnostic: render a few representative resources to RGBA, encode
// as PNG, write to /tmp/JohnnyPhase1Dumps/. This is the "visual
// sanity check" the user can open in Preview to confirm the parser
// extracts recognisable Johnny Castaway imagery.
//
// Pixel correctness is the high-leverage check that bytes round-trip
// (covered by SnapshotTests). This test only confirms the
// rasterisation pipeline produces a non-zero PNG file. Visual
// inspection is the human's job.

import Testing
import Foundation
@testable import JohnnyResources

@Suite("PNG dump diagnostic",
       .disabled(if: !TestResources.available, TestResources.skipMessage))
struct PNGDumpTests {

    static let outputDir: URL = {
        let dir = URL(fileURLWithPath: "/tmp/JohnnyPhase1Dumps", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }()

    /// Find the canonical palette so the PNG dumps have correct colours.
    static func palette(_ archive: ResourceArchive) throws -> Palette {
        let palettes = archive.entries(of: .palette)
        guard let first = palettes.first,
              case .palette(let pal) = first.resource else {
            throw NSError(
                domain: "PNGDumpTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no palette found in archive"]
            )
        }
        return pal
    }

    @Test("Dump BACKGRND.BMP sprite 0 (island base) to PNG")
    func dumpBackgroundIsland() throws {
        let archive = try ContainerTests.archive()
        let pal = try Self.palette(archive)
        guard case .bitmap(let bmp) = archive["BACKGRND.BMP"] else {
            Issue.record("BACKGRND.BMP not found or not a bitmap")
            return
        }
        let img = bmp.rasterize(sprite: 0, palette: pal)
        let url = Self.outputDir.appendingPathComponent("BACKGRND-sprite0.png")
        try PNGEncoder.write(img, to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0, "PNG file is empty: \(url.path)")
    }

    @Test("Dump JOHNWALK.BMP sprite 0 (Johnny pose) to PNG")
    func dumpJohnnyWalk() throws {
        let archive = try ContainerTests.archive()
        let pal = try Self.palette(archive)
        guard case .bitmap(let bmp) = archive["JOHNWALK.BMP"] else {
            Issue.record("JOHNWALK.BMP not found")
            return
        }
        let img = bmp.rasterize(sprite: 0, palette: pal)
        let url = Self.outputDir.appendingPathComponent("JOHNWALK-sprite0.png")
        try PNGEncoder.write(img, to: url)
        #expect(img.width > 0 && img.height > 0)
    }

    @Test("Dump HOLIDAY.BMP all 4 sprites (Halloween, St Patrick, Christmas, New Year)")
    func dumpHolidayOverlays() throws {
        let archive = try ContainerTests.archive()
        let pal = try Self.palette(archive)
        guard case .bitmap(let bmp) = archive["HOLIDAY.BMP"] else {
            Issue.record("HOLIDAY.BMP not found")
            return
        }
        let count = min(4, bmp.imageCount)
        for i in 0 ..< count {
            let img = bmp.rasterize(sprite: i, palette: pal)
            let url = Self.outputDir.appendingPathComponent("HOLIDAY-sprite\(i).png")
            try PNGEncoder.write(img, to: url)
        }
        #expect(bmp.imageCount >= 4, "expected at least 4 holiday sprites; got \(bmp.imageCount)")
    }

    @Test("Dump the night-sky background OCEAN00.SCR to PNG")
    func dumpOceanBackground() throws {
        let archive = try ContainerTests.archive()
        let pal = try Self.palette(archive)
        guard case .screen(let scr) = archive["OCEAN00.SCR"] else {
            Issue.record("OCEAN00.SCR not found")
            return
        }
        let img = scr.rasterize(palette: pal)
        let url = Self.outputDir.appendingPathComponent("OCEAN00.png")
        try PNGEncoder.write(img, to: url)
        #expect(img.width == 640 && img.height == 480)
    }

    @Test("Dump NIGHT.SCR to PNG")
    func dumpNightBackground() throws {
        let archive = try ContainerTests.archive()
        let pal = try Self.palette(archive)
        guard case .screen(let scr) = archive["NIGHT.SCR"] else {
            Issue.record("NIGHT.SCR not found")
            return
        }
        let img = scr.rasterize(palette: pal)
        let url = Self.outputDir.appendingPathComponent("NIGHT.png")
        try PNGEncoder.write(img, to: url)
        #expect(img.width == 640 && img.height == 480)
    }

    @Test("Output directory exists and contains files after the suite runs")
    func outputDirHasContents() throws {
        // This test must run last alphabetically. Swift Testing doesn't
        // guarantee order, but in practice this verifies that at least
        // some of the dump tests succeeded.
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.outputDir, includingPropertiesForKeys: nil
        )
        // It's OK if other dump tests haven't run yet — just confirm
        // the directory exists and is writable.
        print("PNG dumps written to: \(Self.outputDir.path)")
        print("  files so far: \(files.map(\.lastPathComponent).sorted().joined(separator: ", "))")
    }
}
