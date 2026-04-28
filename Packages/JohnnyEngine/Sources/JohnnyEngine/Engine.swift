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
}
