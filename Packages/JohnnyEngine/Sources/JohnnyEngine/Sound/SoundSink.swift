// SoundSink.swift
//
// Protocol through which the engine emits sound-trigger events.
// The engine never plays audio itself — Phase 6 (JohnnyScreenSaver)
// wires up an AVAudioPlayer-based sink. Phase 5 (JohnnyDebugApp) may
// add a toggleable one. All tests use NullSoundSink.
//
// jc_reborn reference: soundPlay() in sound.c:67–147; called from
// ttm.c:326 (opcode 0xC051 PLAY_SAMPLE).

/// The engine calls `playSample(_:)` whenever a TTM script triggers
/// opcode `0xC051 PLAY_SAMPLE`. The id is 0–24 (sound0.wav..sound24.wav;
/// note sound11 and sound13 are absent in the canonical set but the
/// caller does not validate). The sink is responsible for scheduling
/// playback on whatever audio subsystem it owns; the engine does not
/// wait for the sound to finish.
public protocol SoundSink: AnyObject, Sendable {
    func playSample(_ id: Int)
}

/// A no-op sink used in tests and by default when the user has sound off.
public final class NullSoundSink: SoundSink, @unchecked Sendable {
    public init() {}
    public func playSample(_ id: Int) {}
}
