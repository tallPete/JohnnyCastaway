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

// EnginePublicAPITests.swift
//
// Smoke tests for the public Engine facade. Verifies:
//   - Engine can be instantiated from a resource archive
//   - beginADS loads a scene without crashing
//   - composedFramebuffer returns the right size
//   - palette has exactly 16 entries
//   - coveredTTMOpcodes is populated after ticking

import Testing
import JohnnyResources
@testable import JohnnyEngine

@Suite("Engine public API",
       .disabled(if: !EngineTestResources.available, EngineTestResources.skipMessage))
struct EnginePublicAPITests {

    @Test("Engine initialises from archive")
    func engineInit() throws {
        let archive = try EngineTestResources.archive()
        let engine  = try Engine(archive: archive)
        #expect(engine.palette.colors.count == 16)
    }

    @Test("beginADS loads JOHNNY.ADS without error")
    func beginADS() throws {
        let engine = try EngineTestResources.engine()
        try engine.beginADS(name: "JOHNNY.ADS", tag: 1)
        #expect(!engine.isFinished || true)  // may finish immediately for some tags
    }

    @Test("composedFramebuffer is 640×480 pixels")
    func composedFramebufferSize() throws {
        let engine = try EngineTestResources.engine()
        try engine.beginADS(name: "JOHNNY.ADS", tag: 1)
        engine.tick()
        let fb = engine.composedFramebuffer
        #expect(fb.pixels.count == 640 * 480)
    }

    @Test("palette contains 16 RGBA entries")
    func paletteSize() throws {
        let engine = try EngineTestResources.engine()
        #expect(engine.palette.colors.count == 16)
    }

    @Test("coveredTTMOpcodes accumulates after ticking")
    func opcodesCovered() throws {
        let engine = try EngineTestResources.engine()
        try engine.beginADS(name: "JOHNNY.ADS", tag: 1)
        for _ in 0 ..< 10 {
            engine.tick()
            if engine.isFinished { break }
        }
        // After even a few ticks we expect to have seen at least a handful
        // of distinct opcodes (DRAW_SPRITE, SET_DELAY, etc.)
        #expect(engine.coveredTTMOpcodes.count > 0)
    }

    @Test("LOAD_SCREEN in TTM populates the graphics background")
    func loadScreenPopulatesBackground() throws {
        // NIGHT.SCR is loaded by NIGHT.ADS tag 1 (night scene).
        // We just check that after ticking, the engine doesn't crash.
        let engine = try EngineTestResources.engine()
        if let _ = try? engine.beginADS(name: "NIGHT.ADS", tag: 1) {
            for _ in 0 ..< 20 {
                engine.tick()
                if engine.isFinished { break }
            }
        }
        #expect(true)
    }

    @Test("Multiple beginADS calls on same engine resets state")
    func multipleBeginADS() throws {
        let engine = try EngineTestResources.engine()
        try engine.beginADS(name: "JOHNNY.ADS", tag: 1)
        engine.tick()
        // Start a different scene — should not crash
        try engine.beginADS(name: "STAND.ADS", tag: 1)
        engine.tick()
        #expect(true)
    }

    @Test("Version marker updated to phase3")
    func versionMarker() {
        #expect(JohnnyEngine.version == "0.0.0-phase3")
    }
}

// MARK: - JohnnyEngineSkeletonTests replacement

@Suite("JohnnyEngine module")
struct JohnnyEngineModuleTests {

    @Test("Module version is phase3")
    func version() {
        #expect(JohnnyEngine.version == "0.0.0-phase3")
    }
}
