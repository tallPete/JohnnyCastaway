// SceneScheduler.swift
//
// Scene selection (storyPickScene) and island state derivation
// from story.c and story.go (Go port).
//
// Key corrections from Go port (story.go:62–83):
//   • Night: hour < 6 || hour >= 18  (jc_reborn uses (hour%8)∈{0,7})
//   • Holiday: numeric month/day comparison (jc_reborn uses strcmp on MMDD)
//   • Both produce identical results for all holiday windows.
//
// Day-of-story persistence is managed by StoryRunner (the caller). This
// struct is stateless — all random decisions go through an RNG parameter
// so tests can supply a deterministic generator.

import Foundation

// MARK: - SceneScheduler

/// Pure-function scene-selection and island-state derivation.
/// All mutable game state (storyCurrentDay, IslandState) lives in the caller.
public struct SceneScheduler {

    // ---------------------------------------------------------------
    // MARK: Scene picking (story.c:42–62)
    // ---------------------------------------------------------------

    /// Return a random scene matching `wanted` flags, rejecting any
    /// `unwanted` flags, and gated on `day` (0 = any day passes).
    /// - Parameters:
    ///   - wanted:   All these flags must be set on the scene.
    ///   - unwanted: None of these flags may be set.
    ///   - day:      Current story day (1–11). Scene's dayNo=0 always passes.
    ///   - rng:      Randomness source (inout for deterministic testing).
    public static func pickScene(
        wanted:   SceneFlags,
        unwanted: SceneFlags,
        day:      Int,
        rng:      inout some RandomNumberGenerator
    ) -> StoryScene {
        let pool = storyScenes.filter { scene in
            let f = scene.flags
            return (f.isSuperset(of: wanted))
                && (!f.isSuperset(of: unwanted) || unwanted.isEmpty)
                && (scene.dayNo == 0 || scene.dayNo == day)
        }.filter { scene in
            // unwanted: none of the unwanted bits may be set
            scene.flags.intersection(unwanted).isEmpty
        }
        precondition(!pool.isEmpty,
                     "pickScene: no scenes match wanted=\(wanted) unwanted=\(unwanted) day=\(day)")
        return pool.randomElement(using: &rng)!
    }

    // ---------------------------------------------------------------
    // MARK: Night / holiday detection (story.c:94–120; story.go:60–83)
    // ---------------------------------------------------------------

    /// Determine night flag from date/time components.
    /// .fixed (Go fix): `hour < 6 || hour >= 18`
    /// .raw (jc_reborn): `(hour % 8) ∈ {0, 7}` — broken 3-window split
    public static func isNight(date: Date, fidelityMode: FidelityMode = .fixed) -> Bool {
        let comps = Calendar.current.dateComponents([.hour], from: date)
        let hour  = comps.hour ?? 12
        if fidelityMode == .fixed {
            return hour < 6 || hour >= 18
        } else {
            let h = hour % 8
            return h == 0 || h == 7
        }
    }

    /// Determine holiday value (0=none; 1–4) from date.
    /// Uses Go port's numeric month/day comparison (story.go:68–83).
    public static func holiday(date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.month, .day], from: date)
        let m = comps.month ?? 0
        let d = comps.day   ?? 0

        // Halloween  : Oct 29–31
        if m == 10 && (29...31).contains(d) { return 1 }
        // St Patrick : Mar 15–17
        if m ==  3 && (15...17).contains(d) { return 2 }
        // Christmas  : Dec 23–25
        if m == 12 && (23...25).contains(d) { return 3 }
        // New Year   : Dec 29–Jan 1
        if (m == 12 && d >= 29) || (m == 1 && d == 1) { return 4 }

        return 0
    }

    // ---------------------------------------------------------------
    // MARK: Island state from scene (story.c:123–191)
    // ---------------------------------------------------------------

    /// Derive the island position, tide, and raft state for a given scene.
    /// The returned state's `night` and `holiday` fields are NOT set here —
    /// those come from `isNight` / `holiday` above and are merged by the caller.
    public static func islandState(
        for scene:  StoryScene,
        day:        Int,
        rng:        inout some RandomNumberGenerator
    ) -> IslandState {
        var state = IslandState()

        // Low tide (story.c:126–129)
        state.lowTide = scene.flags.contains(.lowTideOK) && Bool.random(using: &rng)

        // Island position (story.c:132–156)
        if scene.flags.contains(.varPosOK) {
            // Three weighted position pools (pick using nested 50/50 coin flips)
            if Bool.random(using: &rng) {
                state.xPos = -222 + Int.random(in: 0..<109, using: &rng)
                state.yPos = -44  + Int.random(in: 0..<128, using: &rng)
            } else if Bool.random(using: &rng) {
                state.xPos = -114 + Int.random(in: 0..<134, using: &rng)
                state.yPos = -14  + Int.random(in: 0..<99,  using: &rng)
            } else {
                state.xPos = -114 + Int.random(in: 0..<119, using: &rng)
                state.yPos = -73  + Int.random(in: 0..<60,  using: &rng)
            }
        } else if scene.flags.contains(.leftIsland) {
            state.xPos = -272
            state.yPos = 0
        } else {
            state.xPos = 0
            state.yPos = 0
        }

        // Raft build progress (story.c:159–181)
        if scene.flags.contains(.noRaft) {
            state.raft = 0
        } else {
            switch day {
            case 0, 1, 2:
                state.raft = 1
            case 3, 4, 5:
                state.raft = day - 1
            default:
                state.raft = 5
            }
        }

        // HOLIDAY_NOK suppresses holiday decoration for this scene
        // (e.g. VISITOR.ADS#3 — cargo ship fills the screen)
        // Caller merges holiday into state; this flag is checked by the caller.

        return state
    }

    // ---------------------------------------------------------------
    // MARK: Story-day update (story.c:65–91)
    // ---------------------------------------------------------------

    /// Return the new story day given the previous persisted state.
    /// - Parameters:
    ///   - previousDay:         Last persisted story day (1–11).
    ///   - previousCalendarDay: Day-of-year when `previousDay` was written.
    ///                          Pass any negative value (e.g. -1) as a
    ///                          "no prior record exists" sentinel — in
    ///                          that case the day is NOT advanced, only
    ///                          clamped to the valid 1–11 range.
    ///   - currentCalendarDay:  Day-of-year today.
    /// Wraps back to 1 after day 11.
    public static func advanceDay(
        previousDay:         Int,
        previousCalendarDay: Int,
        currentCalendarDay:  Int
    ) -> Int {
        var day = previousDay
        // Sentinel: no prior persisted record → don't advance, just clamp.
        // Fixes the off-by-one where a fresh StoryRunner with
        // lastCalendarDay = -1 would always start at day 2 because (-1 != calDay).
        if previousCalendarDay >= 0 && currentCalendarDay != previousCalendarDay {
            day += 1
        }
        if day < 1 || day > 11 { day = 1 }
        return day
    }

    /// Day-of-year for a given `Date` (1–366).
    public static func dayOfYear(from date: Date) -> Int {
        Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1
    }
}
