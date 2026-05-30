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

// EngineDebugState.swift
//
// Observable state model for the debug overlay.
//
// Two modes:
//   .storyLoop    — StoryRunner drives the sequence automatically.
//   .sceneOverride — A specific ADS scene plays; user controls via picker.
//
// Pause/step: when `isPaused`, tick() returns nil. `step(_:)` queues N
// ticks that run even while paused, then re-pauses.
//
// Fidelity mode: .fixed applies Go-port corrections (day/night, IF_IS_RUNNING,
// wave modulo); .raw restores jc_reborn-canonical behaviour for A/B comparison.
//
// Sound: a CapturingSoundSink is created here and passed to both Engine and
// StoryRunner at configure() time; lastSoundTrigger is polled each tick.
//
// Overlay visibility: isOverlayVisible collapses the readout + scrubber rows
// so the full animation frame is visible while leaving transport accessible.

import Foundation
import Observation
import JohnnyEngine
import JohnnyMetalRenderer

// MARK: - EngineDebugState

@Observable @MainActor
public final class EngineDebugState {

    // ---------------------------------------------------------------
    // MARK: Operating mode
    // ---------------------------------------------------------------

    public enum Mode: Equatable {
        case storyLoop
        case sceneOverride
    }
    public var mode: Mode = .storyLoop

    // ---------------------------------------------------------------
    // MARK: Load state
    // ---------------------------------------------------------------

    public private(set) var isLoaded: Bool = false

    // ---------------------------------------------------------------
    // MARK: Owned engine objects
    // ---------------------------------------------------------------

    private(set) var engine:      Engine?
    private(set) var storyRunner: StoryRunner?

    // ---------------------------------------------------------------
    // MARK: Sound capture
    // ---------------------------------------------------------------

    /// Shared sink passed to both Engine and StoryRunner at configure() time.
    /// AppState reads this property to wire up sound before calling configure().
    public let soundSink = CapturingSoundSink()

    // ---------------------------------------------------------------
    // MARK: Playback controls
    // ---------------------------------------------------------------

    public var isPaused: Bool = false
    public private(set) var pendingSteps: Int = 0

    // ---------------------------------------------------------------
    // MARK: Fidelity mode
    // ---------------------------------------------------------------

    public var fidelityMode: FidelityMode = .fixed {
        didSet {
            engine?.fidelityMode      = fidelityMode
            storyRunner?.fidelityMode = fidelityMode
        }
    }

    // ---------------------------------------------------------------
    // MARK: Scene picker
    // ---------------------------------------------------------------

    public var selectedADSName: String = "JOHNNY.ADS"
    public var selectedADSTag:  Int    = 1

    // ---------------------------------------------------------------
    // MARK: Force-date controls
    // ---------------------------------------------------------------

    public var useForceDate: Bool = false
    public var forcedDate: Date = {
        var comps        = DateComponents()
        comps.year       = 2026
        comps.month      = 12
        comps.day        = 24
        return Calendar.current.date(from: comps) ?? Date()
    }()

    // ---------------------------------------------------------------
    // MARK: Overlay visibility
    // ---------------------------------------------------------------

    /// When false the readout and thread scrubber rows are hidden so the
    /// full animation is visible. The transport row remains accessible.
    public var isOverlayVisible: Bool = true

    // ---------------------------------------------------------------
    // MARK: Readout (refreshed each tick)
    // ---------------------------------------------------------------

    public private(set) var storyDay:           Int    = 1
    public private(set) var currentTick:        Int    = 0
    public private(set) var activeThreadCount:  Int    = 0
    public private(set) var coveredOpcodeCount: Int    = 0
    public private(set) var sequenceLabel:      String = "—"
    /// Most recent sound sample ID fired by the engine, or nil if none.
    public private(set) var lastSoundTrigger:   Int?   = nil

    // ---------------------------------------------------------------
    // MARK: Thread snapshots (scrubber)
    // ---------------------------------------------------------------

    /// Live snapshots of every running TTM thread. Updated each tick.
    public private(set) var threadSnapshots: [TTMThreadSnapshot] = []

    // ---------------------------------------------------------------
    // MARK: Internal
    // ---------------------------------------------------------------

    private var rng: SystemRandomNumberGenerator = .init()

    // ---------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------

    public init() {}

    // ---------------------------------------------------------------
    // MARK: Configuration
    // ---------------------------------------------------------------

    /// Wire up an Engine and StoryRunner after resource loading.
    /// Both must have been constructed with `soundSink` as their SoundSink.
    public func configure(engine: Engine, storyRunner: StoryRunner) {
        self.engine      = engine
        self.storyRunner = storyRunner
        self.isLoaded    = true
        self.mode        = .storyLoop
        self.isPaused    = false
        self.currentTick = 0
        self.sequenceLabel   = "Day \(storyRunner.storyDay)"
        self.threadSnapshots = []
        self.lastSoundTrigger = nil
        soundSink.reset()

        // Apply current fidelity mode to freshly wired objects
        engine.fidelityMode      = fidelityMode
        storyRunner.fidelityMode = fidelityMode
    }

    // ---------------------------------------------------------------
    // MARK: User actions
    // ---------------------------------------------------------------

    public func step(_ count: Int) {
        pendingSteps += count
    }

    public func switchToStoryLoop() {
        mode     = .storyLoop
        isPaused = false
    }

    public func playSelectedScene() throws {
        guard let eng = engine else { return }
        mode         = .sceneOverride
        isPaused     = false
        currentTick  = 0
        pendingSteps = 0
        try eng.beginADS(name: selectedADSName, tag: UInt16(selectedADSTag))
        sequenceLabel = "\(selectedADSName) tag \(selectedADSTag)"
    }

    // ---------------------------------------------------------------
    // MARK: Frame provider
    // ---------------------------------------------------------------

    public func tick() -> (Framebuffer, EnginePalette, Int)? {
        switch mode {
        case .storyLoop:    return tickStoryLoop()
        case .sceneOverride: return tickSceneOverride()
        }
    }

    // ---------------------------------------------------------------
    // MARK: Private — story loop tick
    // ---------------------------------------------------------------

    private func tickStoryLoop() -> (Framebuffer, EnginePalette, Int)? {
        guard let runner = storyRunner else { return nil }
        guard !isPaused || pendingSteps > 0 else { return nil }

        do {
            if runner.sequenceFinished {
                try runner.beginNextSequence(rng: &rng)
                storyDay      = runner.storyDay
                sequenceLabel = "Day \(storyDay)"
            }
            let mini = try runner.tick(rng: &rng)

            if pendingSteps > 0 {
                pendingSteps -= 1
                if pendingSteps == 0 { isPaused = true }
            }

            storyDay      = runner.storyDay
            currentTick  += mini
            pollDiagnosticsStoryLoop(runner: runner)
            return (runner.composedFramebuffer, runner.palette, mini)

        } catch {
            sequenceLabel = "Error: \(error.localizedDescription)"
            return nil
        }
    }

    // ---------------------------------------------------------------
    // MARK: Private — scene-override tick
    // ---------------------------------------------------------------

    private func tickSceneOverride() -> (Framebuffer, EnginePalette, Int)? {
        guard let eng = engine else { return nil }
        guard !eng.isFinished else { return nil }
        guard !isPaused || pendingSteps > 0 else { return nil }

        let mini = eng.tick()

        if pendingSteps > 0 {
            pendingSteps -= 1
            if pendingSteps == 0 { isPaused = true }
        }

        currentTick += mini
        pollDiagnostics(engine: eng)
        return (eng.composedFramebuffer, eng.palette, mini)
    }

    // ---------------------------------------------------------------
    // MARK: Private — diagnostics poll (called after every tick)
    // ---------------------------------------------------------------

    private func pollDiagnostics(engine eng: Engine?) {
        if let eng {
            activeThreadCount  = eng.activeThreadCount
            coveredOpcodeCount = eng.coveredTTMOpcodes.count
            threadSnapshots    = eng.threadSnapshots
        }
        lastSoundTrigger = soundSink.lastSampleID
    }

    private func pollDiagnosticsStoryLoop(runner: StoryRunner) {
        let prevActive = activeThreadCount
        activeThreadCount  = runner.activeThreadCount
        coveredOpcodeCount = runner.coveredTTMOpcodes.count
        threadSnapshots    = runner.threadSnapshots
        lastSoundTrigger   = soundSink.lastSampleID

        // Darkness-gap detection: track when active TTM threads drop to 0
        // (= no foreground animation rendering). When a new thread appears
        // again, log how long the gap was.
        if prevActive > 0 && activeThreadCount == 0 {
            darknessStartTick = currentTick
            print("[gap] start (prevActive=\(prevActive) → 0) at tick \(currentTick)")
        } else if prevActive == 0 && activeThreadCount > 0,
                  let start = darknessStartTick {
            let gap = currentTick - start
            print("[gap] end (active=\(activeThreadCount)) after \(gap) mini-ticks (~\(gap * 20)ms)")
            darknessStartTick = nil
        }

        // Multi-thread spawning report. When more than 1 thread is active
        // we want to know which scene caused it (multiple Johnnys symptom).
        if activeThreadCount >= 2 && prevActive < 2 {
            let names = threadSnapshots.map { "\($0.slotName):\($0.tag)" }
                .joined(separator: ", ")
            print("[concurrency] \(activeThreadCount) threads active simultaneously: \(names)")
        }
    }

    private var darknessStartTick: Int? = nil
}
