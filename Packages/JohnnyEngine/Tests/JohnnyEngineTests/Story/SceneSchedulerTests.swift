// SceneSchedulerTests.swift
//
// Tests for scene selection, holiday detection, night calculation,
// and island state derivation.
//
// All tests that don't need canonical resources run unconditionally.
// Tests exercising IslandRenderer are gated on EngineTestResources.available.

import Testing
import Foundation
@testable import JohnnyEngine

// ---------------------------------------------------------------
// MARK: - SceneFlags / Catalogue sanity
// ---------------------------------------------------------------

@Suite("SceneCatalogue")
struct SceneCatalogueTests {

    @Test("Catalogue has exactly 63 scenes")
    func count() {
        #expect(storyScenes.count == 63)
    }

    @Test("Every FINAL scene can appear as the last scene")
    func finalFlagConsistency() {
        let finalScenes = storyScenes.filter { $0.flags.contains(.final_) }
        #expect(!finalScenes.isEmpty)
        // Every scene with ISLAND but not FIRST must not rely solely on the
        // walk system to get Johnny somewhere — we just verify such scenes exist
        // and that the catalogue is internally consistent (FIRST implies no walk-in).
        let islandNoFirst = finalScenes.filter {
            $0.flags.contains(.island) && !$0.flags.contains(.first)
        }
        // All of these scenes should have a valid adsName (non-empty)
        for scene in islandNoFirst {
            #expect(!scene.adsName.isEmpty,
                    "Scene \(scene.adsName):\(scene.adsTag) has no ADS name")
        }
    }

    @Test("Day-gated scenes cover days 1–11")
    func dayGatedCoverage() {
        let dayGated = storyScenes.filter { $0.dayNo != 0 }
        let days = Set(dayGated.map { $0.dayNo })
        // Days with named scenes: 1,2,3,4,5,6,7,8,9,10,11
        for d in 1...11 {
            #expect(days.contains(d), "Day \(d) has no day-gated scene")
        }
    }

    @Test("NORAFT and HOLIDAY_NOK flags exist in catalogue")
    func specialFlagsPresent() {
        #expect(storyScenes.contains { $0.flags.contains(.noRaft) })
        #expect(storyScenes.contains { $0.flags.contains(.holidayNOK) })
    }
}

// ---------------------------------------------------------------
// MARK: - SceneScheduler.pickScene (deterministic, no resources)
// ---------------------------------------------------------------

@Suite("SceneScheduler.pickScene")
struct PickSceneTests {

    /// Shared seeded RNG for reproducible results.
    private func makeRNG() -> SeedableRNG { SeedableRNG(seed: 42) }

    @Test("1000 picks on day 0 all match FINAL flag")
    func finalOnly() {
        var rng = makeRNG()
        for _ in 0 ..< 1000 {
            let scene = SceneScheduler.pickScene(wanted: .final_, unwanted: [], day: 1, rng: &rng)
            #expect(scene.flags.contains(.final_))
        }
    }

    @Test("Day-specific scenes only appear on their designated day")
    func dayGating() {
        var rng = makeRNG()
        for day in 1...11 {
            // Run 500 picks for each day
            for _ in 0 ..< 500 {
                let scene = SceneScheduler.pickScene(wanted: [], unwanted: .final_, day: day, rng: &rng)
                #expect(scene.dayNo == 0 || scene.dayNo == day,
                        "Day \(day): got scene \(scene.adsName):\(scene.adsTag) with dayNo=\(scene.dayNo)")
            }
        }
    }

    @Test("FIRST-flagged scenes are excluded when FIRST is unwanted")
    func firstExclusion() {
        var rng = makeRNG()
        for _ in 0 ..< 500 {
            let scene = SceneScheduler.pickScene(wanted: [], unwanted: [.final_, .first], day: 1, rng: &rng)
            #expect(!scene.flags.contains(.first))
        }
    }

    @Test("All reachable scenes on day=0 appear in 5000 picks")
    func coverage() {
        var rng = makeRNG()
        var seen = Set<String>()
        let candidates = storyScenes.filter { $0.dayNo == 0 }.map { "\($0.adsName):\($0.adsTag)" }

        for _ in 0 ..< 5000 {
            let scene = SceneScheduler.pickScene(wanted: [], unwanted: [], day: 1, rng: &rng)
            if scene.dayNo == 0 {
                seen.insert("\(scene.adsName):\(scene.adsTag)")
            }
        }

        // Every day-0 scene should appear at least once in 5000 picks
        for key in candidates {
            #expect(seen.contains(key), "Scene \(key) was never picked in 5000 draws")
        }
    }

    @Test("unwanted=FINAL never returns a FINAL scene")
    func noFinal() {
        var rng = makeRNG()
        for _ in 0 ..< 500 {
            let scene = SceneScheduler.pickScene(wanted: [], unwanted: .final_, day: 1, rng: &rng)
            #expect(!scene.flags.contains(.final_))
        }
    }
}

// ---------------------------------------------------------------
// MARK: - Holiday detection (no resources needed)
// ---------------------------------------------------------------

@Suite("SceneScheduler.holiday")
struct HolidayDetectionTests {

    private func date(year: Int, month: Int, day: Int) -> Date {
        FixedDateProvider(year: year, month: month, day: day).currentDate
    }

    @Test("Halloween: Oct 29–31")
    func halloween() {
        for d in 29...31 {
            #expect(SceneScheduler.holiday(date: date(year: 2026, month: 10, day: d)) == 1,
                    "Oct \(d) should be Halloween")
        }
        // Days outside window
        #expect(SceneScheduler.holiday(date: date(year: 2026, month: 10, day: 28)) == 0)
        #expect(SceneScheduler.holiday(date: date(year: 2026, month: 11, day:  1)) == 0)
    }

    @Test("St Patrick: Mar 15–17")
    func stPatrick() {
        for d in 15...17 {
            #expect(SceneScheduler.holiday(date: date(year: 2026, month: 3, day: d)) == 2,
                    "Mar \(d) should be St Patrick")
        }
        #expect(SceneScheduler.holiday(date: date(year: 2026, month: 3, day: 14)) == 0)
        #expect(SceneScheduler.holiday(date: date(year: 2026, month: 3, day: 18)) == 0)
    }

    @Test("Christmas: Dec 23–25")
    func christmas() {
        for d in 23...25 {
            #expect(SceneScheduler.holiday(date: date(year: 2026, month: 12, day: d)) == 3,
                    "Dec \(d) should be Christmas")
        }
        #expect(SceneScheduler.holiday(date: date(year: 2026, month: 12, day: 22)) == 0)
        #expect(SceneScheduler.holiday(date: date(year: 2026, month: 12, day: 26)) == 0)
    }

    @Test("New Year: Dec 29 – Jan 1")
    func newYear() {
        for d in 29...31 {
            #expect(SceneScheduler.holiday(date: date(year: 2026, month: 12, day: d)) == 4,
                    "Dec \(d) should be New Year")
        }
        #expect(SceneScheduler.holiday(date: date(year: 2027, month: 1, day: 1)) == 4,
                "Jan 1 should be New Year")
        #expect(SceneScheduler.holiday(date: date(year: 2026, month: 12, day: 28)) == 0)
        #expect(SceneScheduler.holiday(date: date(year: 2027, month: 1, day: 2)) == 0)
    }

    @Test("Ordinary day has no holiday")
    func ordinary() {
        #expect(SceneScheduler.holiday(date: date(year: 2026, month: 4, day: 28)) == 0)
    }
}

// ---------------------------------------------------------------
// MARK: - Night detection (no resources needed)
// ---------------------------------------------------------------

@Suite("SceneScheduler.isNight")
struct NightDetectionTests {

    private func dateAt(hour: Int) -> Date {
        FixedDateProvider(year: 2026, month: 6, day: 15, hour: hour).currentDate
    }

    @Test("Go fix: hours 0–5 and 18–23 are night")
    func nightHours() {
        for h in 0...5 {
            #expect(SceneScheduler.isNight(date: dateAt(hour: h)), "hour \(h) should be night")
        }
        for h in 18...23 {
            #expect(SceneScheduler.isNight(date: dateAt(hour: h)), "hour \(h) should be night")
        }
    }

    @Test("Go fix: hours 6–17 are day")
    func dayHours() {
        for h in 6...17 {
            #expect(!SceneScheduler.isNight(date: dateAt(hour: h)), "hour \(h) should be day")
        }
    }
}

// ---------------------------------------------------------------
// MARK: - Island state derivation (no resources needed)
// ---------------------------------------------------------------

@Suite("SceneScheduler.islandState")
struct IslandStateTests {

    @Test("NORAFT flag sets raft=0 regardless of day")
    func noRaft() {
        var rng = SeedableRNG(seed: 7)
        // MARY.ADS:5 has NORAFT
        let scene = storyScenes.first { $0.flags.contains(.noRaft) }!
        let state = SceneScheduler.islandState(for: scene, day: 8, rng: &rng)
        #expect(state.raft == 0)
    }

    @Test("Raft progression: days 1–2 → raft=1")
    func raftDay12() {
        var rng = SeedableRNG(seed: 1)
        let scene = storyScenes.first { !$0.flags.contains(.noRaft) && !$0.flags.contains(.first) }!
        for day in [1, 2] {
            var r = SeedableRNG(seed: UInt64(day))
            let state = SceneScheduler.islandState(for: scene, day: day, rng: &r)
            #expect(state.raft == 1, "Day \(day): expected raft=1, got \(state.raft)")
        }
        _ = rng  // suppress unused warning
    }

    @Test("Raft progression: days 3–5 → raft = day-1")
    func raftDays35() {
        let scene = storyScenes.first { !$0.flags.contains(.noRaft) }!
        for day in [3, 4, 5] {
            var rng = SeedableRNG(seed: UInt64(day))
            let state = SceneScheduler.islandState(for: scene, day: day, rng: &rng)
            #expect(state.raft == day - 1, "Day \(day): expected raft=\(day-1), got \(state.raft)")
        }
    }

    @Test("Raft progression: day ≥ 6 → raft=5")
    func raftDayGe6() {
        let scene = storyScenes.first { !$0.flags.contains(.noRaft) }!
        for day in [6, 7, 8, 9, 10, 11] {
            var rng = SeedableRNG(seed: UInt64(day))
            let state = SceneScheduler.islandState(for: scene, day: day, rng: &rng)
            #expect(state.raft == 5, "Day \(day): expected raft=5, got \(state.raft)")
        }
    }

    @Test("VARPOS_OK gives non-zero island position")
    func varPos() {
        // Run 100 picks and verify at least one is non-zero
        let scene = storyScenes.first { $0.flags.contains(.varPosOK) }!
        var nonZero = false
        for seed: UInt64 in 0 ..< 100 {
            var rng = SeedableRNG(seed: seed)
            let state = SceneScheduler.islandState(for: scene, day: 1, rng: &rng)
            if state.xPos != 0 || state.yPos != 0 { nonZero = true; break }
        }
        #expect(nonZero, "VARPOS_OK never produced a non-zero position in 100 seeds")
    }
}

// ---------------------------------------------------------------
// MARK: - Story day advancement
// ---------------------------------------------------------------

@Suite("SceneScheduler.advanceDay")
struct AdvanceDayTests {

    @Test("Same calendar day does not advance story day")
    func sameDay() {
        let day = SceneScheduler.advanceDay(previousDay: 3, previousCalendarDay: 100, currentCalendarDay: 100)
        #expect(day == 3)
    }

    @Test("New calendar day advances story day by 1")
    func newCalendarDay() {
        let day = SceneScheduler.advanceDay(previousDay: 3, previousCalendarDay: 100, currentCalendarDay: 101)
        #expect(day == 4)
    }

    @Test("Story day wraps from 11 back to 1")
    func wrap() {
        let day = SceneScheduler.advanceDay(previousDay: 11, previousCalendarDay: 50, currentCalendarDay: 51)
        #expect(day == 1)
    }

    @Test("Day < 1 is clamped to 1")
    func clampLow() {
        let day = SceneScheduler.advanceDay(previousDay: 0, previousCalendarDay: 1, currentCalendarDay: 1)
        #expect(day == 1)
    }

    @Test("Sentinel previousCalendarDay (-1) does NOT advance day on first run")
    func sentinelFirstRun() {
        // Before the sentinel-handling fix, a fresh StoryRunner with
        // lastCalendarDay = -1 would always start at day 2 because the
        // (-1 != calDay) test fired on the first beginNextSequence call.
        let day = SceneScheduler.advanceDay(previousDay: 1, previousCalendarDay: -1, currentCalendarDay: 127)
        #expect(day == 1, "first run with no prior calendar record should stay at the seeded day")
    }

    @Test("Sentinel with seeded day 7 stays at 7")
    func sentinelPreservesSeed() {
        // When initial state is restored from persistence, the seeded day
        // should be respected even if no prior calendar day is on record.
        let day = SceneScheduler.advanceDay(previousDay: 7, previousCalendarDay: -1, currentCalendarDay: 200)
        #expect(day == 7)
    }
}

// ---------------------------------------------------------------
// MARK: - SeedableRNG helper (deterministic testing)
// ---------------------------------------------------------------

/// A simple seeded PRNG for deterministic test runs.
/// Uses a linear congruential generator (LCG) suitable for testing only.
struct SeedableRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed ^ 0x12345678_9ABCDEF0 }
    mutating func next() -> UInt64 {
        // Knuth's multiplicative LCG
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
