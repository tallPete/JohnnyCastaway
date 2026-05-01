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
        NSLog("[Johnny] playSample(%d)", id)
    }
}
