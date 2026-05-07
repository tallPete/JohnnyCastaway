// AVAudioPlayerSoundSink.swift
//
// AVAudioPlayer-backed SoundSink for the .saver host.
//
// Sound files: sound0.wav – sound24.wav in the Sierra resource folder
// (alongside RESOURCE.MAP / RESOURCE.001).  sound11 and sound13 are
// absent from the canonical set; any other missing files are silently
// skipped so a partial install still works.
//
// Playback model: one sound at a time, matching jc_reborn (sound.c:67–147).
// A new playSample() call stops the currently-playing sound and starts
// the new one from the beginning.  No mixing, no queue.
//
// All public methods are called on the main thread (animateOneFrame()
// runs on the ScreenSaverView timer, which fires on the main run loop).
// AVAudioPlayer is safe to use on the main thread.

import Foundation
import AVFoundation
import JohnnyEngine

final class AVAudioPlayerSoundSink: SoundSink, @unchecked Sendable {

    private var players: [Int: AVAudioPlayer] = [:]
    private weak var current: AVAudioPlayer?

    /// Most recent sample ID passed to `playSample`, for the debug overlay.
    /// Single-thread (main run loop), so plain `var` is fine.
    private(set) var lastSampleID: Int? = nil

    /// Eagerly load all present sound files from `folder` so that
    /// `playSample()` never blocks on I/O.
    init(folder: URL) {
        for id in 0 ... 24 {
            let url = folder.appendingPathComponent("sound\(id).wav")
            guard let player = try? AVAudioPlayer(contentsOf: url) else {
                // Missing files (sound11, sound13, …) are normal — skip silently.
                continue
            }
            player.prepareToPlay()
            players[id] = player
        }
        NSLog("[Johnny] AVAudioPlayerSoundSink: loaded %d/25 sound file(s)", players.count)
    }

    // MARK: SoundSink

    func playSample(_ id: Int) {
        guard let player = players[id] else {
            // Not a log-worthy event for absent canonical files (11, 13).
            return
        }
        current?.stop()
        player.currentTime = 0
        player.play()
        current = player
        lastSampleID = id
        NSLog("[Johnny] playSample(%d)", id)
    }

    /// Stop all playback immediately AND release the AVAudioPlayer
    /// instances.
    ///
    /// AVAudioPlayer keeps audio buffered in the hardware pipeline and
    /// continues playing even after its owning object is released by ARC.
    /// Calling `stop()` halts the buffer, but the AudioQueue resources
    /// only fully drain when the player is deallocated — and on Tahoe
    /// the legacyScreenSaver host frequently leaks the saver view, which
    /// means our players never get released by ARC and a stale `current`
    /// reference can be re-played by a stray engine tick.  Dropping the
    /// dictionary here forces immediate teardown of all audio queues.
    func stopAll() {
        current?.stop()
        current = nil
        // Stop every loaded player first (in case any other reference
        // is still holding one), then drop the strong references so
        // the underlying AudioQueueObject is destroyed.
        players.values.forEach { $0.stop() }
        players.removeAll()
        NSLog("[Johnny] AVAudioPlayerSoundSink: stopAll (released %d player(s))", players.count)
    }
}
