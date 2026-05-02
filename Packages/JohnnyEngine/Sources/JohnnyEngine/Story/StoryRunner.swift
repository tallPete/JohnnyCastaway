// StoryRunner.swift
//
// High-level story orchestrator — the Swift equivalent of storyPlay()
// in jc_reborn's story.c (story.c:195–278).
//
// Manages:
//   • Story-day persistence and calendar-day advancement
//   • Scene selection (SceneScheduler.pickScene)
//   • Island setup + wave animation (IslandRenderer)
//   • Walk animation between scenes (WalkController + PathFinder)
//   • ADS scene playback (ADSScheduler)
//   • Holiday overlay layer
//
// Usage:
//   let runner = try StoryRunner(archive: archive,
//                                dateProvider: SystemDateProvider(),
//                                sound: NullSoundSink())
//   while true {
//       runner.beginNextSequence()          // pick + set up one day's scenes
//       while !runner.sequenceFinished {
//           runner.tick()                   // advance one step
//           let frame = runner.composedFramebuffer
//           // render frame
//       }
//   }

import Foundation
import JohnnyResources

// MARK: - Story state machine

private enum StoryState {
    case idle
    case setupIsland
    case walking(WalkController, walkBmp: Bitmap, bgBmp: Bitmap)
    case playingScene(adsName: String, adsTag: Int)
    case fadeOut
    case done
}

// MARK: - StoryRunner

public final class StoryRunner {

    // ---------------------------------------------------------------
    // MARK: Dependencies
    // ---------------------------------------------------------------

    private let cache:        ResourceCache
    private let graphics:     GraphicsState
    private let scheduler:    ADSScheduler
    private let islandRdr:    IslandRenderer
    private let dateProvider: DateProvider
    private let sound:        SoundSink

    // ---------------------------------------------------------------
    // MARK: Story state
    // ---------------------------------------------------------------

    /// Current day in the 11-day story cycle.
    public private(set) var storyDay: Int = 1

    /// Last calendar day-of-year that was used to advance `storyDay`.
    private var lastCalendarDay: Int = -1

    /// Current island configuration.
    public private(set) var islandState: IslandState = IslandState()

    // ---------------------------------------------------------------
    // MARK: Sequence planning
    // ---------------------------------------------------------------

    // The planned scene queue for the current day's sequence:
    //   scenePlan[0..<finalSceneIndex] = non-final scenes
    //   scenePlan[finalSceneIndex]     = final scene
    private var scenePlan:       [StoryScene] = []
    private var scenePlanIndex:  Int          = 0

    private var prevSpot: Int = -1
    private var prevHdg:  Int = -1

    private var state: StoryState = .idle
    private var playingTicks: Int = 0

    // ---------------------------------------------------------------
    // MARK: Exposed palette
    // ---------------------------------------------------------------

    public private(set) var palette: EnginePalette

    // ---------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------

    public init(
        archive:       ResourceArchive,
        dateProvider:  DateProvider  = SystemDateProvider(),
        sound:         SoundSink     = NullSoundSink()
    ) throws {
        let rcache      = ResourceCache(archive: archive)
        self.cache      = rcache
        self.graphics   = GraphicsState()
        self.sound      = sound
        self.dateProvider = dateProvider
        self.islandRdr  = IslandRenderer(cache: rcache, graphics: graphics)
        self.scheduler  = ADSScheduler(cache: rcache, graphics: graphics, sound: sound)

        // Load first palette
        let pal = try rcache.firstPalette()
        self.palette = EnginePalette(from: pal)
        graphics.transparentIndex = self.palette.transparentIndex
    }

    // ---------------------------------------------------------------
    // MARK: Public interface
    // ---------------------------------------------------------------

    // ---------------------------------------------------------------
    // MARK: Fidelity mode
    // ---------------------------------------------------------------

    /// Propagated to ADSScheduler (IF_IS_RUNNING), IslandRenderer (wave
    /// modulo), and SceneScheduler.isNight(). Changing it takes effect at
    /// the start of the next tick for ADS/wave; at the next
    /// beginNextSequence() call for day/night.
    public var fidelityMode: FidelityMode = .fixed {
        didSet {
            scheduler.fidelityMode = fidelityMode
            islandRdr.fidelityMode = fidelityMode
        }
    }

    // ---------------------------------------------------------------
    // MARK: Public interface
    // ---------------------------------------------------------------

    /// True when the current sequence (day) has fully completed.
    public var sequenceFinished: Bool { state == .done }

    /// Composed 640×480 indexed framebuffer for the current frame.
    public var composedFramebuffer: Framebuffer { scheduler.composedFramebuffer }

    /// Number of actively-running TTM threads (for the debug overlay).
    public var activeThreadCount: Int { scheduler.activeThreadCount }

    /// Total number of allocated threads (any non-zero isRunning). Used by
    /// the debug overlay to distinguish "scene complete" (numThreads==0) from
    /// "scene running but blocked" (numThreads>0, activeThreadCount==0).
    public var allocatedThreadCount: Int { scheduler.numThreads }

    /// Per-thread isRunning states (for debugging "stuck scene" issues).
    public var threadRunStates: [Int] { scheduler.threads.map { $0.isRunning } }

    /// Snapshot of each running thread's state (for the debug overlay scrubber).
    public var threadSnapshots: [TTMThreadSnapshot] { scheduler.threadSnapshots }

    /// Set of TTM opcodes covered since the last beginADS call (for the debug overlay).
    public var coveredTTMOpcodes: Set<UInt16> { TTMInterpreter.coveredOpcodes }

    /// Begin a new story sequence using the current date from `dateProvider`.
    /// Call once, then call `tick()` until `sequenceFinished`.
    public func beginNextSequence(rng: inout some RandomNumberGenerator) throws {
        // Advance story day if calendar day changed (story.c:65–91)
        let now          = dateProvider.currentDate
        let calDay       = SceneScheduler.dayOfYear(from: now)
        storyDay         = SceneScheduler.advanceDay(
            previousDay:         storyDay,
            previousCalendarDay: lastCalendarDay,
            currentCalendarDay:  calDay
        )
        lastCalendarDay  = calDay

        // Determine night + holiday from date (story.c:94–120, Go fixes)
        islandState.night   = SceneScheduler.isNight(date: now, fidelityMode: fidelityMode)
        islandState.holiday = SceneScheduler.holiday(date: now)

        // Plan the scene queue: pick a final scene, then 6–19 non-final scenes
        try planSequence(rng: &rng)

        // Reset walk state
        prevSpot = -1
        prevHdg  = -1
        scenePlanIndex = 0

        state = .idle
    }

    /// Advance one step of the engine (one TTM tick, or one walk frame).
    /// Returns the number of ticks consumed (for real-time pacing).
    @discardableResult
    public func tick(rng: inout some RandomNumberGenerator) throws -> Int {
        switch state {

        case .idle:
            // Transition: set up next planned scene (or walk to it first)
            try transitionToNextScene(rng: &rng)
            return 0

        case .setupIsland:
            // This state is handled synchronously in transitionToNextScene
            state = .idle
            return 0

        case .walking(let walker, let walkBmp, let bgBmp):
            // The walk thread is claimed in startWalk(); look it up here.
            // Framebuffer is a value type, so we copy → mutate → write back.
            guard let walkThread = scheduler.threads.first(where: { $0.isRunning == 1 }) else {
                // Lost the walk thread (shouldn't happen). Bail to .idle so
                // we don't deadlock; the next tick will replan.
                print("[story] walk thread missing, bailing to idle")
                state = .idle
                return 0
            }
            var layer = walkThread.layer
            let delay = walker.animate(onto: &layer, walkBmp: walkBmp,
                                       bgBmp: bgBmp, graphics: graphics)
            walkThread.layer = layer
            // Tick background/holiday (wave animation)
            scheduler.backgroundThread.timer = max(scheduler.backgroundThread.timer - 1, 0)
            if scheduler.backgroundThread.timer == 0 && scheduler.backgroundThread.isRunning != 0 {
                scheduler.backgroundThread.timer = scheduler.backgroundThread.delay
                scheduler.onBackgroundTick?()
            }
            if delay == 0 {
                let walkIdx = scheduler.threads.firstIndex(where: { $0 === walkThread }) ?? -1
                print("[walk] done, freeing thread idx=\(walkIdx)")
                walkThread.free()
                scheduler.numThreads = max(0, scheduler.numThreads - 1)
                state = .idle
            }
            return delay

        case .playingScene(let n, let t):
            if scheduler.isFinished {
                // Scene done — mark idle to pick next
                print("[story] scene done: \(n) tag=\(t), advancing to \(scenePlanIndex + 2)/\(scenePlan.count)")
                scenePlanIndex += 1
                prevSpot = scenePlan[scenePlanIndex - 1].spotEnd
                prevHdg  = scenePlan[scenePlanIndex - 1].hdgEnd
                state = .idle
                return 0
            }
            playingTicks += 1
            if playingTicks % 200 == 0 {
                let states = scheduler.threads.enumerated()
                    .filter { $0.element.isRunning != 0 }
                    .map { "[\($0.offset)]=\($0.element.isRunning)" }
                    .joined(separator: " ")
                print("[story] still playing \(n) tag=\(t) after \(playingTicks) ticks; threads: \(states); numThreads=\(scheduler.numThreads)")
            }

            // Per-scene watchdog timeout. Some ADS scripts (e.g. STAND.ADS
            // tag=5 cycling MJAMBWLK tags 41/43/44/65) form a self-
            // sustaining IF_LASTPLAYED chunk graph that never naturally
            // terminates. The original DOS game appears to have cut these
            // short via wall-clock pacing pressure that we don't reproduce.
            // 8000 playingTicks is well past the longest legitimate scene
            // (~3000 in observed runs), so anything beyond it is stuck.
            // Force-kill all threads, mark scheduler finished, and let the
            // story advance to the next scene on the following tick.
            if playingTicks > 8000 {
                print("[story] WATCHDOG: force-ending \(n) tag=\(t) after \(playingTicks) ticks (likely chunk-graph cycle)")
                for thr in scheduler.threads where thr.isRunning != 0 {
                    thr.free()
                }
                scheduler.numThreads = 0
                // Don't recurse — fall through; next tick will see
                // isFinished and advance to the next scene.
                return 0
            }
            return scheduler.tick()

        case .fadeOut, .done:
            state = .done
            return 0
        }
    }

    // ---------------------------------------------------------------
    // MARK: Private — scene planning
    // ---------------------------------------------------------------

    private func planSequence(rng: inout some RandomNumberGenerator) throws {
        scenePlan = []

        // Pick the final scene (always FINAL flagged)
        let finalScene = SceneScheduler.pickScene(
            wanted:   .final_,
            unwanted: [],
            day:      storyDay,
            rng:      &rng
        )

        // Derive island state from the final scene
        if finalScene.flags.contains(.island) {
            var derived = SceneScheduler.islandState(for: finalScene, day: storyDay, rng: &rng)
            derived.night   = islandState.night
            derived.holiday = finalScene.flags.contains(.holidayNOK) ? 0 : islandState.holiday
            islandState     = derived
        } else {
            islandState.xPos = 0
            islandState.yPos = 0
        }

        // Non-final scenes (6–19 of them, story.c:232–254)
        var nonFinals: [StoryScene] = []
        if !finalScene.flags.contains(.first) {
            var wantedFlags   = SceneFlags()
            var unwantedFlags: SceneFlags = .final_

            if islandState.lowTide   { wantedFlags.insert(.lowTideOK) }
            if islandState.xPos != 0 || islandState.yPos != 0 { wantedFlags.insert(.varPosOK) }

            let count = 6 + Int.random(in: 0..<14, using: &rng)
            for i in 0 ..< count {
                let scene = SceneScheduler.pickScene(
                    wanted:   wantedFlags,
                    unwanted: unwantedFlags,
                    day:      storyDay,
                    rng:      &rng
                )
                nonFinals.append(scene)
                if i == 0 { unwantedFlags.insert(.first) }
            }
        }

        scenePlan = nonFinals + [finalScene]
    }

    // ---------------------------------------------------------------
    // MARK: Private — scene transitions
    // ---------------------------------------------------------------

    private func transitionToNextScene(rng: inout some RandomNumberGenerator) throws {
        guard scenePlanIndex < scenePlan.count else {
            state = .done
            return
        }

        let scene = scenePlan[scenePlanIndex]
        let isFinal = (scenePlanIndex == scenePlan.count - 1)

        // Set up island background for the first scene in the sequence
        if scenePlanIndex == 0 {
            if scenePlan.last?.flags.contains(.island) == true {
                try setupIsland(state: islandState, rng: &rng)
            } else {
                graphics.dx = 0
                graphics.dy = 0
                graphics.initEmptyBackground()
            }
        }

        // If the previous scene's TTM did a LOAD_SCREEN (e.g. a fishing
        // close-up replaced the ocean island with ISLAND2.SCR), the island
        // background is gone. Restore it before this island scene plays —
        // otherwise this scene's walk and sprites render on top of the
        // wrong background.
        if scene.flags.contains(.island) && !graphics.isIslandBackground {
            print("[story] restoring island background (clobbered by previous LOAD_SCREEN)")
            try setupIsland(state: islandState, rng: &rng)
        }

        // Walk to scene's start spot if we know where we are
        if prevSpot != -1 && scene.spotStart != 0 &&
           prevSpot != scene.spotStart {
            print(String(format: "[story] walk %d → %d (hdg %d → %d)",
                         prevSpot, scene.spotStart, prevHdg, scene.hdgStart))
            try startWalk(from: prevSpot, fromHdg: prevHdg,
                          to: scene.spotStart, toHdg: scene.hdgStart,
                          rng: &rng)
            // Mark the walk's destination as our "current" position so when
            // the walk completes and tick() re-enters transitionToNextScene
            // for this same scene, the walk-condition is now false and we
            // fall through to scheduler.beginADS instead of looping.
            prevSpot = scene.spotStart
            prevHdg  = scene.hdgStart
            return
        }

        // Set island dx/dy for the scene (story.c:243–244)
        if scene.flags.contains(.island) {
            let xOffset = scene.flags.contains(.leftIsland) ? 272 : 0
            graphics.dx = islandState.xPos + xOffset
            graphics.dy = islandState.yPos
        } else if isFinal {
            graphics.dx = 0
            graphics.dy = 0
        }

        // Sound 0 for day-specific scenes (story.c:247)
        if scene.dayNo != 0 { sound.playSample(0) }

        // Play the ADS scene
        let script = try cache.adsScript(named: scene.adsName)
        try scheduler.beginADS(script: script, tag: UInt16(scene.adsTag))
        playingTicks = 0
        print(String(format: "[story] scene[%d/%d] %@ tag=%d → activeThreads=%d numThreads=%d, dx=%d dy=%d",
                     scenePlanIndex + 1, scenePlan.count,
                     scene.adsName, scene.adsTag,
                     scheduler.activeThreadCount, scheduler.numThreads,
                     graphics.dx, graphics.dy))
        state = .playingScene(adsName: scene.adsName, adsTag: scene.adsTag)
    }

    // ---------------------------------------------------------------
    // MARK: Private — island setup
    // ---------------------------------------------------------------

    private func setupIsland(state: IslandState, rng: inout some RandomNumberGenerator) throws {
        try islandRdr.setup(state: state, rng: &rng)

        // Hook background thread (wave animation, ads.c:865–889)
        scheduler.backgroundThread.isRunning = 3  // special background state
        scheduler.backgroundThread.delay     = 8
        scheduler.backgroundThread.timer     = 8  // island.c:146: delay = timer = 8
        scheduler.onBackgroundTick = { [weak self] in
            guard let self else { return }
            self.islandRdr.animate(state: self.islandState)
        }

        // Holiday decoration layer
        scheduler.holidayLayer = try islandRdr.holidayLayer(state: state)
    }

    // ---------------------------------------------------------------
    // MARK: Private — walk setup
    // ---------------------------------------------------------------

    private func startWalk(
        from: Int, fromHdg: Int,
        to:   Int, toHdg:   Int,
        rng:  inout some RandomNumberGenerator
    ) throws {
        let path     = calcPath(from: from, to: to, rng: &rng)
        let walkBmp  = try cache.bitmap(named: "JOHNWALK.BMP")
        let bgBmp: Bitmap
        if let slotBmp = islandRdr.backgroundSlot.bitmaps[0] {
            bgBmp = slotBmp
        } else {
            bgBmp = try cache.bitmap(named: "BACKGRND.BMP")
        }

        // Claim a free TTM thread to host the walk layer. The .walking case
        // in tick() draws into this thread's layer (which is composited into
        // the final frame). The thread is freed when the walk completes; if
        // we get pre-empted, the next scheduler.beginADS will reset everything.
        guard let walkThread = scheduler.threads.first(where: { $0.isRunning == 0 }) else {
            print("[story] no free thread for walk; skipping")
            return
        }
        let walkIdx = scheduler.threads.firstIndex(where: { $0 === walkThread }) ?? -1
        walkThread.isRunning = 1
        walkThread.layer     = GraphicsState.newLayer()
        scheduler.numThreads += 1
        print("[walk] claimed thread idx=\(walkIdx) (active=\(scheduler.activeThreadCount) numThreads=\(scheduler.numThreads))")

        let walkCtrl = WalkController(from: from, fromHdg: fromHdg,
                                      to: to, toHdg: toHdg,
                                      path: path)
        graphics.dx = islandState.xPos
        graphics.dy = islandState.yPos

        state = .walking(walkCtrl, walkBmp: walkBmp, bgBmp: bgBmp)
    }
}

// MARK: - Equatable conformance for StoryState (for sequenceFinished check)

extension StoryState: Equatable {
    static func == (lhs: StoryState, rhs: StoryState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.setupIsland, .setupIsland),
             (.fadeOut, .fadeOut),
             (.done, .done):
            return true
        case let (.playingScene(n1, t1), .playingScene(n2, t2)):
            return n1 == n2 && t1 == t2
        default:
            return false
        }
    }
}
