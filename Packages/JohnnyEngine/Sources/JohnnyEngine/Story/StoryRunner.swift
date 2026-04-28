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
            guard var layer = scheduler.threads.first(where: { $0.isRunning == 1 })?.layer else {
                // No thread slot allocated for walk yet — use a scratch layer
                var scratch = GraphicsState.newLayer()
                let delay = walker.animate(onto: &scratch, walkBmp: walkBmp,
                                           bgBmp: bgBmp, graphics: graphics)
                if delay == 0 { state = .idle }
                scheduler.tick()
                return delay
            }
            let delay = walker.animate(onto: &layer, walkBmp: walkBmp,
                                       bgBmp: bgBmp, graphics: graphics)
            // Tick background/holiday (wave animation)
            scheduler.backgroundThread.timer = max(scheduler.backgroundThread.timer - 1, 0)
            if scheduler.backgroundThread.timer == 0 && scheduler.backgroundThread.isRunning != 0 {
                scheduler.backgroundThread.timer = scheduler.backgroundThread.delay
                scheduler.onBackgroundTick?()
            }
            if delay == 0 { state = .idle }
            return delay

        case .playingScene:
            if scheduler.isFinished {
                // Scene done — mark idle to pick next
                scenePlanIndex += 1
                prevSpot = scenePlan[scenePlanIndex - 1].spotEnd
                prevHdg  = scenePlan[scenePlanIndex - 1].hdgEnd
                state = .idle
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

        // Walk to scene's start spot if we know where we are
        if prevSpot != -1 && scene.spotStart != 0 &&
           prevSpot != scene.spotStart {
            try startWalk(from: prevSpot, fromHdg: prevHdg,
                          to: scene.spotStart, toHdg: scene.hdgStart,
                          rng: &rng)
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
        scheduler.backgroundThread.timer     = 0
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

        // Set up a scratch TTM thread for the walk layer
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
