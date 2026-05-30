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

import Foundation
import Testing
@testable import JohnnyDebug
import JohnnyEngine

@Suite("JohnnyDebug skeleton")
struct JohnnyDebugSkeletonTests {

    @Test("Module is importable and exposes a version marker")
    func versionMarker() {
        #expect(JohnnyDebug.version == "0.0.0-phase5")
    }

    @Test("Engine and renderer dependencies resolve")
    func dependenciesResolve() {
        let versions = JohnnyDebug.dependencyVersions
        #expect(versions.engine == "0.0.0-phase3")
        #expect(versions.renderer == "0.0.0-phase4")
    }
}

@Suite("EngineDebugState")
struct EngineDebugStateTests {

    @Test("Initial state: not loaded, storyLoop mode, not paused")
    @MainActor
    func initialState() {
        let state = EngineDebugState()
        #expect(!state.isLoaded)
        #expect(state.mode == .storyLoop)
        #expect(!state.isPaused)
        #expect(state.currentTick == 0)
        #expect(state.pendingSteps == 0)
    }

    @Test("step() increments pendingSteps")
    @MainActor
    func stepAccumulates() {
        let state = EngineDebugState()
        state.step(5)
        #expect(state.pendingSteps == 5)
        state.step(10)
        #expect(state.pendingSteps == 15)
    }

    @Test("tick() returns nil when not loaded")
    @MainActor
    func tickNilWhenNotLoaded() {
        let state = EngineDebugState()
        #expect(state.tick() == nil)
    }

    @Test("tick() returns nil when paused with no pending steps")
    @MainActor
    func tickNilWhenPaused() {
        let state = EngineDebugState()
        state.isPaused = true
        #expect(state.tick() == nil)
    }

    @Test("switchToStoryLoop() sets mode and clears pause")
    @MainActor
    func switchToStoryLoop() {
        let state  = EngineDebugState()
        state.mode = .sceneOverride
        state.isPaused = true
        state.switchToStoryLoop()
        #expect(state.mode == .storyLoop)
        #expect(!state.isPaused)
    }

    @Test("useForceDate defaults to false; forcedDate defaults to Christmas 2026")
    @MainActor
    func defaultForcedDate() {
        let state = EngineDebugState()
        #expect(!state.useForceDate)
        let cal   = Calendar.current
        let comps = cal.dateComponents([.month, .day], from: state.forcedDate)
        #expect(comps.month == 12)
        #expect(comps.day   == 24)
    }

    @Test("fidelityMode defaults to .fixed")
    @MainActor
    func fidelityModeDefault() {
        let state = EngineDebugState()
        #expect(state.fidelityMode == .fixed)
    }

    @Test("isOverlayVisible defaults to true")
    @MainActor
    func overlayVisibleDefault() {
        let state = EngineDebugState()
        #expect(state.isOverlayVisible)
    }

    @Test("isOverlayVisible can be toggled")
    @MainActor
    func overlayVisibleToggle() {
        let state = EngineDebugState()
        state.isOverlayVisible = false
        #expect(!state.isOverlayVisible)
        state.isOverlayVisible = true
        #expect(state.isOverlayVisible)
    }

    @Test("threadSnapshots is empty before loading")
    @MainActor
    func threadSnapshotsEmptyBeforeLoad() {
        let state = EngineDebugState()
        #expect(state.threadSnapshots.isEmpty)
    }

    @Test("lastSoundTrigger is nil before any sound fires")
    @MainActor
    func lastSoundTriggerNilInitially() {
        let state = EngineDebugState()
        #expect(state.lastSoundTrigger == nil)
    }

    @Test("CapturingSoundSink records sample IDs")
    func capturingSoundSinkRecords() {
        let sink = CapturingSoundSink()
        #expect(sink.lastSampleID == nil)
        sink.playSample(7)
        #expect(sink.lastSampleID == 7)
        sink.playSample(12)
        #expect(sink.lastSampleID == 12)
        sink.reset()
        #expect(sink.lastSampleID == nil)
    }
}

@Suite("FidelityMode")
struct FidelityModeTests {

    @Test("FidelityMode has exactly two cases")
    func casesCount() {
        #expect(FidelityMode.allCases.count == 2)
    }

    @Test("isNight .fixed: night = hour < 6 or >= 18")
    func isNightFixed() {
        let cal = Calendar.current
        func makeDate(hour: Int) -> Date {
            var c = cal.dateComponents([.year, .month, .day], from: Date())
            c.hour = hour; c.minute = 0; c.second = 0
            return cal.date(from: c)!
        }
        for h in 0..<6 {
            #expect(SceneScheduler.isNight(date: makeDate(hour: h), fidelityMode: .fixed),
                    "hour \(h) should be night (.fixed)")
        }
        for h in 6..<18 {
            #expect(!SceneScheduler.isNight(date: makeDate(hour: h), fidelityMode: .fixed),
                    "hour \(h) should be day (.fixed)")
        }
        for h in 18..<24 {
            #expect(SceneScheduler.isNight(date: makeDate(hour: h), fidelityMode: .fixed),
                    "hour \(h) should be night (.fixed)")
        }
    }

    @Test("isNight .raw: uses (hour % 8) ∈ {0, 7}")
    func isNightRaw() {
        let cal = Calendar.current
        func makeDate(hour: Int) -> Date {
            var c = cal.dateComponents([.year, .month, .day], from: Date())
            c.hour = hour; c.minute = 0; c.second = 0
            return cal.date(from: c)!
        }
        let expectedNight: Set<Int> = [0, 7, 8, 15, 16, 23]
        for h in 0..<24 {
            let expected = expectedNight.contains(h)
            #expect(SceneScheduler.isNight(date: makeDate(hour: h), fidelityMode: .raw) == expected,
                    "hour \(h) raw night mismatch")
        }
    }
}
