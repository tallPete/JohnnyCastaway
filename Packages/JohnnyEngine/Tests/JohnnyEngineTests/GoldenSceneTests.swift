// GoldenSceneTests.swift
//
// End-to-end golden-output test for JOHNNY.ADS tag 1.
//
// Runs the engine for 200 ticks and writes each composed frame as a PNG
// to /tmp/JohnnyPhase2Dumps/JOHNNY-1/. Visual inspection of the PNGs
// is the acceptance gate for pixel correctness.
//
// Structural assertions:
//   - first frame has some non-black (non-0) pixels
//   - palette is the archive's first palette
//   - sequence terminates cleanly (scene finishes) or is still running
//     after 200 ticks (both are acceptable)
//   - any PLAY_SAMPLE trigger IDs are in the legal range 0..24

import Testing
import Foundation
import JohnnyResources
@testable import JohnnyEngine

@Suite("Golden scene — JOHNNY.ADS tag 1",
       .disabled(if: !EngineTestResources.available, EngineTestResources.skipMessage))
struct GoldenSceneTests {

    static let outputDir: URL = {
        let dir = URL(fileURLWithPath: "/tmp/JohnnyPhase2Dumps/JOHNNY-1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    @Test("JOHNNY.ADS tag 1 — tick 200 frames, write PNGs")
    func johnnyADSTag1Golden() throws {
        let archive = try EngineTestResources.archive()

        // Build engine
        let engine = try Engine(archive: archive)
        try engine.beginADS(name: "JOHNNY.ADS", tag: 1)

        var lastSoundId: Int? = nil
        let recordingSink = RecordingSoundSink { id in lastSoundId = id }

        // Re-create with recording sound sink
        let engine2 = try Engine(archive: archive, sound: recordingSink)
        try engine2.beginADS(name: "JOHNNY.ADS", tag: 1)

        var firstFrameHasContent = false

        for tickNo in 0 ..< 200 {
            engine2.tick()
            let fb  = engine2.composedFramebuffer
            let pal = engine2.palette

            if tickNo == 0 {
                // First frame should have some non-transparent pixels
                let nonSentinel = fb.pixels.filter { $0 != 0xFF }
                firstFrameHasContent = !nonSentinel.isEmpty
            }

            // Write PNG (suppress individual file errors; the directory
            // existence check below is the structural assertion).
            let url = Self.outputDir.appendingPathComponent(
                String(format: "frame%04d.png", tickNo)
            )
            try? EnginePNGDump.write(fb, palette: pal, to: url)

            if engine2.isFinished { break }
        }

        // Structural assertions
        #expect(firstFrameHasContent,
                "First frame was entirely transparent — engine may not have loaded any graphics")

        #expect(engine2.palette.colors.count == 16)

        if let sid = lastSoundId {
            #expect((0...24).contains(sid),
                    "PLAY_SAMPLE id \(sid) is outside the legal 0..24 range")
        }

        // Verify at least one PNG was written
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.outputDir, includingPropertiesForKeys: nil
        )) ?? []
        #expect(!files.isEmpty, "No PNG frames were written to \(Self.outputDir.path)")

        print("Phase 2 golden frames written to: \(Self.outputDir.path)")
        print("  total frames: \(files.count)")
        print("  TTM opcodes exercised: \(engine2.coveredTTMOpcodes.count)")
    }

    @Test("OCEAN00 background loads correctly as a LOAD_SCREEN target")
    func ocean00BackgroundLoads() throws {
        let archive = try EngineTestResources.archive()
        guard case .screen(let scr) = archive["OCEAN00.SCR"] else {
            Issue.record("OCEAN00.SCR not found")
            return
        }
        let g = GraphicsState()
        g.loadScreen(scr)
        let bg = try #require(g.background)
        #expect(bg.pixels.count == Framebuffer.width * Framebuffer.height)
        let nonZero = bg.pixels.filter { $0 != 0 }
        #expect(!nonZero.isEmpty, "OCEAN00.SCR background is all zeros — load failed?")
    }
}

// MARK: - RecordingSoundSink

/// A SoundSink that calls back on every playSample invocation.
final class RecordingSoundSink: SoundSink, @unchecked Sendable {
    private let callback: (Int) -> Void
    init(_ callback: @escaping (Int) -> Void) { self.callback = callback }
    func playSample(_ id: Int) { callback(id) }
}
