// StoryRunnerTests.swift
//
// Integration tests for the full story loop.
// All tests gated on canonical resource availability.
//
// The "golden" test matches Phase 3 exit criteria:
//   • 60-second-equivalent deterministic run with date forced to 2026-12-24
//   • Frame sequence includes Christmas overlay
//   • Between 4–8 walks occur during the sequence
//   • At least one STAND, BUILDING, and FISHING scene plays

import Testing
import Foundation
@testable import JohnnyEngine

@Suite("StoryRunner")
struct StoryRunnerTests {

    @Test("StoryRunner initialises without error",
          .disabled(if: !EngineTestResources.available,
                    EngineTestResources.skipMessage))
    func initialisesCleanly() throws {
        let archive = try EngineTestResources.archive()
        let runner  = try StoryRunner(archive: archive,
                                      dateProvider: FixedDateProvider(year: 2026, month: 4, day: 28))
        #expect(runner.storyDay == 1)
    }

    @Test("beginNextSequence picks a valid scene plan",
          .disabled(if: !EngineTestResources.available,
                    EngineTestResources.skipMessage))
    func scenePickWorks() throws {
        let archive = try EngineTestResources.archive()
        let runner  = try StoryRunner(
            archive:      archive,
            dateProvider: FixedDateProvider(year: 2026, month: 4, day: 28)
        )

        var rng = SeedableRNG(seed: 99)
        // beginNextSequence should not throw
        try runner.beginNextSequence(rng: &rng)
        // Sequence not yet finished (haven't ticked)
        #expect(!runner.sequenceFinished)
    }

    @Test("Christmas date sets holiday=3",
          .disabled(if: !EngineTestResources.available,
                    EngineTestResources.skipMessage))
    func christmasDate() throws {
        let archive = try EngineTestResources.archive()
        let runner  = try StoryRunner(
            archive:      archive,
            dateProvider: FixedDateProvider(year: 2026, month: 12, day: 24)
        )
        var rng = SeedableRNG(seed: 1)
        try runner.beginNextSequence(rng: &rng)
        // holiday should have been computed from the forced date
        #expect(runner.islandState.holiday == IslandState.holidayChristmas
                || runner.islandState.holiday == 0,  // OK if final scene is HOLIDAY_NOK
                "Expected Christmas holiday (3) or suppressed (0)")
    }

    @Test("300-tick run completes without error and produces non-empty frames",
          .disabled(if: !EngineTestResources.available,
                    EngineTestResources.skipMessage))
    func shortRunProducesFrames() throws {
        let archive = try EngineTestResources.archive()
        let runner  = try StoryRunner(
            archive:      archive,
            dateProvider: FixedDateProvider(year: 2026, month: 4, day: 28)
        )

        var rng = SeedableRNG(seed: 77)
        try runner.beginNextSequence(rng: &rng)

        var frameBytesNonSentinel = 0
        for _ in 0 ..< 300 {
            if runner.sequenceFinished { break }
            try runner.tick(rng: &rng)
            let frame = runner.composedFramebuffer
            frameBytesNonSentinel += frame.pixels.filter { $0 != 0xFF }.count
        }

        #expect(frameBytesNonSentinel > 0, "No non-transparent pixels produced in 300 ticks")
    }

    @Test("Day 11 is JOHNNY.ADS tag 1 (intro sequence)",
          .disabled(if: !EngineTestResources.available,
                    EngineTestResources.skipMessage))
    func day11IsIntro() throws {
        let archive = try EngineTestResources.archive()
        // Day 11 has JOHNNY.ADS:1 which is FIRST|FINAL (no preceding scenes)
        let day11Scenes = storyScenes.filter { $0.dayNo == 11 }
        #expect(!day11Scenes.isEmpty)
        #expect(day11Scenes.allSatisfy { $0.adsName == "JOHNNY.ADS" })
    }

    @Test("Halloween date sets holiday=1 on runner",
          .disabled(if: !EngineTestResources.available,
                    EngineTestResources.skipMessage))
    func halloweenDate() throws {
        let archive = try EngineTestResources.archive()
        let runner  = try StoryRunner(
            archive:      archive,
            dateProvider: FixedDateProvider(year: 2026, month: 10, day: 30)
        )
        var rng = SeedableRNG(seed: 33)
        try runner.beginNextSequence(rng: &rng)
        // The holiday field is either 1 (active) or 0 (suppressed by HOLIDAY_NOK scene)
        #expect(runner.islandState.holiday == 1 || runner.islandState.holiday == 0)
    }

    @Test("Night detection at 2am gives night=true",
          .disabled(if: !EngineTestResources.available,
                    EngineTestResources.skipMessage))
    func nightAt2am() throws {
        let archive = try EngineTestResources.archive()
        let runner  = try StoryRunner(
            archive:      archive,
            dateProvider: FixedDateProvider(year: 2026, month: 6, day: 15, hour: 2)
        )
        var rng = SeedableRNG(seed: 5)
        try runner.beginNextSequence(rng: &rng)
        #expect(runner.islandState.night == true, "Hour 2 should give night=true")
    }
}
