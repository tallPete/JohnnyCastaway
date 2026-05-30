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

// SoundSink.swift
//
// Protocol through which the engine emits sound-trigger events.
// The engine never plays audio itself — Phase 6 (JohnnyScreenSaver)
// wires up an AVAudioPlayer-based sink. Phase 5 (JohnnyDebugApp) may
// add a toggleable one. All tests use NullSoundSink.
//
// jc_reborn reference: soundPlay() in sound.c:67–147; called from
// ttm.c:326 (opcode 0xC051 PLAY_SAMPLE).

import Foundation

/// The engine calls `playSample(_:)` whenever a TTM script triggers
/// opcode `0xC051 PLAY_SAMPLE`. The id is 0–24 (sound0.wav..sound24.wav;
/// note sound11 and sound13 are absent in the canonical set but the
/// caller does not validate). The sink is responsible for scheduling
/// playback on whatever audio subsystem it owns; the engine does not
/// wait for the sound to finish.
public protocol SoundSink: AnyObject, Sendable {
    func playSample(_ id: Int)
    /// Stop any currently-playing audio immediately.  Called by the
    /// screensaver host on teardown so that in-flight sounds do not
    /// continue after the screensaver is dismissed.  Implementations
    /// that own no audio hardware (NullSoundSink, CapturingSoundSink)
    /// leave this as a no-op.
    func stopAll()
}

/// A no-op sink used in tests and by default when the user has sound off.
public final class NullSoundSink: SoundSink, @unchecked Sendable {
    public init() {}
    public func playSample(_ id: Int) {}
    public func stopAll() {}
}

/// A sink that records the most recent sample ID for display in the debug
/// overlay. Thread-safe via a simple lock so it can be read from the main
/// thread while the engine ticks.
public final class CapturingSoundSink: SoundSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastSampleID: Int? = nil

    public init() {}

    public func playSample(_ id: Int) {
        lock.withLock { _lastSampleID = id }
    }

    public func stopAll() {}   // no audio hardware to stop

    /// The sample ID most recently passed to `playSample(_:)`, or nil if
    /// nothing has been played yet since the sink was created.
    public var lastSampleID: Int? {
        lock.withLock { _lastSampleID }
    }

    /// Clear the captured value (e.g. when loading new resources).
    public func reset() {
        lock.withLock { _lastSampleID = nil }
    }
}
