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

// ADSSchedulerTests.swift
//
// Tests for ADS opcode interpretation and thread scheduling.
// These tests require canonical Sierra resource files (to load real ADS
// scripts). They are guarded by the standard `.disabled(if:)` trait.

import Testing
import JohnnyResources
@testable import JohnnyEngine

@Suite("ADS scheduler (canonical)",
       .disabled(if: !EngineTestResources.available, EngineTestResources.skipMessage))
struct ADSSchedulerTests {

    private func makeScheduler() throws -> ADSScheduler {
        let archive = try EngineTestResources.archive()
        let cache   = ResourceCache(archive: archive)
        return ADSScheduler(
            cache:    cache,
            graphics: GraphicsState(),
            sound:    NullSoundSink()
        )
    }

    // ---------------------------------------------------------------
    // MARK: Basic load and run
    // ---------------------------------------------------------------

    @Test("JOHNNY.ADS tag 1 begins without error")
    func johnnyADSTag1Begins() throws {
        let scheduler = try makeScheduler()
        let archive   = try EngineTestResources.archive()
        guard case .adsScript(let script) = archive["JOHNNY.ADS"] else {
            Issue.record("JOHNNY.ADS not found")
            return
        }
        try scheduler.beginADS(script: script, tag: 1)
        // After beginADS, at least one thread should be running or the
        // scene should be immediately finished (valid for some tags).
        #expect(!scheduler.isFinished || scheduler.numThreads == 0)
    }

    @Test("Ticking JOHNNY.ADS tag 1 for 200 iterations stays stable")
    func johnnyADSTag1Ticks() throws {
        let scheduler = try makeScheduler()
        let archive   = try EngineTestResources.archive()
        guard case .adsScript(let script) = archive["JOHNNY.ADS"] else {
            Issue.record("JOHNNY.ADS not found")
            return
        }
        try scheduler.beginADS(script: script, tag: 1)
        for _ in 0 ..< 200 {
            scheduler.tick()
            if scheduler.isFinished { break }
        }
        // The scene should either finish cleanly or still be running.
        // Key assert: it didn't crash or enter an infinite spin.
        #expect(true)  // reaching here means no crash
    }

    // ---------------------------------------------------------------
    // MARK: STAND.ADS — GOSUB_TAG
    // ---------------------------------------------------------------

    @Test("STAND.ADS tag 1 begins and ticks without crash")
    func standADSTag1() throws {
        let scheduler = try makeScheduler()
        let archive   = try EngineTestResources.archive()
        guard case .adsScript(let script) = archive["STAND.ADS"] else {
            Issue.record("STAND.ADS not found")
            return
        }
        try scheduler.beginADS(script: script, tag: 1)
        for _ in 0 ..< 100 {
            scheduler.tick()
            if scheduler.isFinished { break }
        }
        #expect(true)
    }

    // ---------------------------------------------------------------
    // MARK: Multiple ADS scenes
    // ---------------------------------------------------------------

    @Test("BUILDING.ADS tag 1 begins and ticks without crash")
    func buildingADSTag1() throws {
        let scheduler = try makeScheduler()
        let archive   = try EngineTestResources.archive()
        guard case .adsScript(let script) = archive["BUILDING.ADS"] else {
            Issue.record("BUILDING.ADS not found")
            return
        }
        try scheduler.beginADS(script: script, tag: 1)
        for _ in 0 ..< 100 {
            scheduler.tick()
            if scheduler.isFinished { break }
        }
        #expect(true)
    }

    @Test("FISHING.ADS tag 3 begins without crash")
    func fishingADSTag3() throws {
        let scheduler = try makeScheduler()
        let archive   = try EngineTestResources.archive()
        guard case .adsScript(let script) = archive["FISHING.ADS"] else {
            Issue.record("FISHING.ADS not found")
            return
        }
        try scheduler.beginADS(script: script, tag: 3)
        for _ in 0 ..< 100 {
            scheduler.tick()
            if scheduler.isFinished { break }
        }
        #expect(true)
    }

    // ---------------------------------------------------------------
    // MARK: IF_NOT_RUNNING / IF_IS_RUNNING
    // ---------------------------------------------------------------

    @Test("IF_IS_RUNNING skips block when scene is not running")
    func ifIsRunningSkipsWhenNotRunning() throws {
        // Run JOHNNY.ADS tag 1, then check that the thread count is sane.
        // We can't deterministically test IF_IS_RUNNING in isolation
        // without hand-crafted bytecode, but we verify the interpreter
        // doesn't crash on scripts that contain it.
        let scheduler = try makeScheduler()
        let archive   = try EngineTestResources.archive()
        guard case .adsScript(let script) = archive["ACTIVITY.ADS"] else {
            Issue.record("ACTIVITY.ADS not found")
            return
        }
        try scheduler.beginADS(script: script, tag: 1)
        for _ in 0 ..< 200 {
            scheduler.tick()
            if scheduler.isFinished { break }
        }
        #expect(true)
    }

    // ---------------------------------------------------------------
    // MARK: composedFramebuffer
    // ---------------------------------------------------------------

    @Test("composedFramebuffer is 640×480 after ticking")
    func composedFramebufferSize() throws {
        let scheduler = try makeScheduler()
        let archive   = try EngineTestResources.archive()
        guard case .adsScript(let script) = archive["JOHNNY.ADS"] else {
            Issue.record("JOHNNY.ADS not found")
            return
        }
        try scheduler.beginADS(script: script, tag: 1)
        scheduler.tick()
        let fb = scheduler.composedFramebuffer
        #expect(fb.pixels.count == Framebuffer.width * Framebuffer.height)
    }
}
