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

// Engine.swift
//
// Public façade for the JohnnyEngine package. Replaces the Phase-0
// version marker with a real engine that can load and run ADS scenes.
//
// Usage:
//   let engine = try Engine(archive: archive)
//   try engine.beginADS(name: "JOHNNY.ADS", tag: 1)
//   while !engine.isFinished {
//       engine.tick()
//       let frame  = engine.composedFramebuffer  // [UInt8], 640×480 indexed
//       let palette = engine.palette             // EnginePalette (16 RGBA)
//   }

import Foundation
import JohnnyResources

/// Version of this module.
public enum JohnnyEngine {
    public static let version = "0.0.0-phase3"
}

// ---------------------------------------------------------------
// MARK: - TTMThreadSnapshot
// ---------------------------------------------------------------

/// A point-in-time snapshot of one running TTM thread, for display
/// in the debug overlay's thread scrubber.
public struct TTMThreadSnapshot: Sendable {
    /// Name of the TTM resource (e.g. "JOHNSC7.TTM").
    public let slotName: String
    /// ADS tag this thread was launched with.
    public let tag: UInt16
    /// Current instruction-pointer byte offset into the TTM bytecode.
    public let ip: Int
    /// Opcode at the current IP (nil if the thread is at end-of-bytecode).
    public let currentOpcode: UInt16?
    /// Ticks remaining on this thread's per-UPDATE timer.
    public let timer: Int
    /// Ticks between UPDATE calls (SET_DELAY / TIMER value).
    public let delay: Int
}

/// The main engine object. Not thread-safe; call from one thread only.
public final class Engine {

    // ---------------------------------------------------------------
    // MARK: Public state
    // ---------------------------------------------------------------

    /// True when the current ADS scene has finished.
    public var isFinished: Bool { scheduler.isFinished }

    /// The current composed 640×480 framebuffer (indexed 0..15).
    public var composedFramebuffer: Framebuffer { scheduler.composedFramebuffer }

    /// The active palette.
    public private(set) var palette: EnginePalette

    // ---------------------------------------------------------------
    // MARK: Engine internals
    // ---------------------------------------------------------------

    private let cache:     ResourceCache
    private let graphics:  GraphicsState
    private let sound:     SoundSink
    private let scheduler: ADSScheduler

    // ---------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------

    /// Create an engine from a parsed resource archive.
    /// If `paletteOverride` is nil, the first palette found in the
    /// archive is used.
    public init(
        archive: ResourceArchive,
        paletteOverride: Palette? = nil,
        sound: SoundSink = NullSoundSink()
    ) throws {
        self.sound    = sound
        let rcache    = ResourceCache(archive: archive)
        self.cache    = rcache
        self.graphics = GraphicsState()

        let pal: Palette
        if let p = paletteOverride {
            pal = p
        } else {
            pal = try rcache.firstPalette()
        }
        self.palette  = EnginePalette(from: pal)
        graphics.transparentIndex = self.palette.transparentIndex

        self.scheduler = ADSScheduler(
            cache:    rcache,
            graphics: graphics,
            sound:    sound
        )
    }

    // ---------------------------------------------------------------
    // MARK: Scene control
    // ---------------------------------------------------------------

    /// Load and begin a named ADS scene at the given tag. Resets all
    /// TTM thread and slot state. May be called again after the
    /// previous scene finishes.
    public func beginADS(name: String, tag: UInt16) throws {
        TTMInterpreter.coveredOpcodes = []
        // Standalone scene playback has no story-level offset; reset here.
        // (StoryRunner sets dx/dy itself before calling scheduler.beginADS.)
        graphics.dx = 0
        graphics.dy = 0
        let script = try cache.adsScript(named: name)
        try scheduler.beginADS(script: script, tag: tag)
    }

    /// Advance the engine by one TTM-loop iteration (one batch of opcodes
    /// per thread, then timer accounting). Advances all threads whose
    /// timers have reached zero.
    ///
    /// Returns the number of ticks consumed (the `mini` from the ADS
    /// timer loop). Callers can use this to implement real-time pacing.
    @discardableResult
    public func tick() -> Int {
        scheduler.tick()
    }

    // ---------------------------------------------------------------
    // MARK: Diagnostics
    // ---------------------------------------------------------------

    /// Set of TTM opcodes encountered since the last `beginADS` call.
    public var coveredTTMOpcodes: Set<UInt16> {
        TTMInterpreter.coveredOpcodes
    }

    /// Number of TTM threads currently running in the active scene.
    public var activeThreadCount: Int { scheduler.activeThreadCount }

    /// Snapshot of each running thread's state (slot name, tag, IP, opcode,
    /// timer). Updated live on every `tick()` call.
    public var threadSnapshots: [TTMThreadSnapshot] { scheduler.threadSnapshots }

    // ---------------------------------------------------------------
    // MARK: Fidelity mode
    // ---------------------------------------------------------------

    /// Switch between Go-port-corrected (.fixed) and jc_reborn-canonical
    /// (.raw) behaviour. Takes effect immediately for IF_IS_RUNNING and
    /// wave-counter changes; day/night takes effect at the next sequence.
    public var fidelityMode: FidelityMode = .fixed {
        didSet { scheduler.fidelityMode = fidelityMode }
    }
}
