// ADSScheduler.swift
//
// ADS (scene-orchestration) script interpreter and run loop.
// Translates ads.c from jc_reborn:
//   adsLoad()            — ads.c:89–190
//   adsPlayChunk()       — ads.c:445–630
//   adsPlayTriggeredChunks() — ads.c:633–655
//   adsPlay() main loop  — ads.c:658–804
//   adsAddScene()        — ads.c:219–269
//   adsStopScene()       — ads.c:272–277
//   isSceneRunning()     — ads.c:297–311
//   adsRandomXxx()       — ads.c:338–405
//
// IF_IS_RUNNING fix: `inSkipBlock = !isSceneRunning(...)` — matches
// both current jc_reborn (C) and Go-port corrected behaviour.
//
// The background/island thread (adsInitIsland) is a Phase 3 concern.
// For Phase 2 we leave the background thread slot nil / isRunning=0.

import Foundation
import JohnnyResources

// ---------------------------------------------------------------
// MARK: - ADS chunk (IF_LASTPLAYED bookmark)
// ---------------------------------------------------------------

/// Bookmarked IF_LASTPLAYED or IF_NOT_RUNNING chunk offset.
/// Translates struct TAdsChunk in ads.c:49–53.
struct AdsChunk {
    var slot:   UInt16
    var tag:    UInt16
    var offset: Int    // data offset immediately after the two-word args
}

// ---------------------------------------------------------------
// MARK: - Random-block operation
// ---------------------------------------------------------------

private enum RandOpType { case addScene, stopScene, nop }

private struct RandOp {
    var type:     RandOpType
    var slot:     UInt16
    var tag:      UInt16
    var numPlays: UInt16
    var weight:   UInt16
}

// ---------------------------------------------------------------
// MARK: - ADSScheduler
// ---------------------------------------------------------------

/// Drives a complete ADS scene: loads TTM slots, executes opcodes,
/// manages the TTM thread pool, and fires IF_LASTPLAYED triggers.
///
/// Call `play(adsName:tag:)` to run one complete scene to completion.
/// For the "golden test" harness `tick()` advances one step at a time.
final class ADSScheduler {

    // ---------------------------------------------------------------
    // MARK: State
    // ---------------------------------------------------------------

    let cache:    ResourceCache
    let graphics: GraphicsState
    let sound:    SoundSink

    /// Controls IF_IS_RUNNING inversion and other jc_reborn-vs-Go differences.
    var fidelityMode: FidelityMode = .fixed

    /// The raw ADS bytecode being interpreted.
    private var adsData:     Data   = Data()
    private var adsDataSize: Int    = 0

    /// TTM slots (one per referenced TTM in the ADS RES: table).
    var ttmSlots:   [TTMSlot]   = (0 ..< MAX_TTM_SLOTS).map { _ in TTMSlot() }

    /// Running threads.
    var threads:    [TTMThread] = (0 ..< MAX_TTM_THREADS).map { _ in TTMThread() }

    /// Background thread (island wave animation). isRunning==3 means active.
    var backgroundThread = TTMThread()

    /// Called each time the background thread timer fires.
    /// Phase 3 sets this to `islandRenderer.animate(state:)`.
    var onBackgroundTick: (() -> Void)?

    /// Optional holiday decoration layer; composited on top of all TTM layers.
    var holidayLayer: Framebuffer? = nil

    /// Number of currently running foreground threads.
    var numThreads: Int = 0

    /// IF_LASTPLAYED bookmarks (global).
    private var adsChunks: [AdsChunk] = []

    /// IF_LASTPLAYED_LOCAL bookmark (at most 1).
    private var adsChunkLocal: AdsChunk? = nil

    /// ADS tag offsets (for GOSUB_TAG lookups).
    private var adsTags: [(id: UInt16, offset: Int)] = []

    /// Random-block state.
    private var randOps: [RandOp] = []

    /// Whether END opcode has fired.
    private var stopRequested = false

    // ---------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------

    init(cache: ResourceCache, graphics: GraphicsState, sound: SoundSink) {
        self.cache    = cache
        self.graphics = graphics
        self.sound    = sound
    }

    // ---------------------------------------------------------------
    // MARK: Public interface
    // ---------------------------------------------------------------

    var isFinished: Bool { numThreads == 0 }

    /// Number of TTM threads currently in the running state (isRunning == 1).
    var activeThreadCount: Int { threads.filter { $0.isRunning == 1 }.count }

    /// Snapshot of each running thread's current state for the debug overlay.
    var threadSnapshots: [TTMThreadSnapshot] {
        threads.filter { $0.isRunning == 1 }.map { t in
            let opcode: UInt16? = {
                guard let slot = t.ttmSlot, t.ip + 1 < slot.bytecode.count else { return nil }
                return readUInt16LE(slot.bytecode, at: t.ip)
            }()
            return TTMThreadSnapshot(
                slotName: t.ttmSlot?.resourceName ?? "—",
                tag:          t.sceneTag,
                ip:           t.ip,
                currentOpcode: opcode,
                timer:        t.timer,
                delay:        t.delay
            )
        }
    }

    /// Snapshot taken at the same point jc_reborn calls grUpdateDisplay —
    /// after play() but before post-process (free / spawn). Returned by
    /// `composedFramebuffer`. Without this snapshot, the displayed frame
    /// would reflect the AFTER-post-process state, causing Johnny to
    /// disappear for one frame between sub-scenes (thread A freed, thread
    /// B not yet drawn). nil before the first tick — composedFramebuffer
    /// falls back to a live composite then.
    private var snapshotFramebuffer: Framebuffer?

    /// Composite the current state into a fresh framebuffer.
    /// Used both by the per-tick snapshot and by the live-composite
    /// fallback before the first tick.
    /// Order: background → active TTM layers → holiday decoration.
    /// Includes any non-zero isRunning (matches jc_reborn graphics.c:196).
    private func composeFramebufferNow() -> Framebuffer {
        var dest = Framebuffer()
        let activeLayers = threads.filter { $0.isRunning != 0 }.map { $0.layer }
        graphics.composite(threadLayers: activeLayers, into: &dest)
        if let holiday = holidayLayer {
            dest.composite(layer: holiday)
        }
        return dest
    }

    /// Composed output for the current frame. Returns the per-tick
    /// snapshot taken between play() and post-process, falling back to a
    /// live composite if no snapshot has been taken yet.
    var composedFramebuffer: Framebuffer {
        snapshotFramebuffer ?? composeFramebufferNow()
    }

    /// Refresh the snapshot from the current live state. Called by
    /// StoryRunner during .walking ticks (which bypass scheduler.tick()
    /// entirely) so the walker's drawings on walkThread.layer are
    /// actually visible. Without this, the snapshot taken at the end of
    /// the previous .playingScene tick stays on screen for the entire
    /// walk duration — the user sees the previous scene's last frame
    /// frozen while Johnny "teleports" to the next scene's start spot.
    func refreshSnapshot() {
        snapshotFramebuffer = composeFramebufferNow()
    }

    // ---------------------------------------------------------------
    // MARK: Setup — adsLoad() translation, ads.c:89–190
    // ---------------------------------------------------------------

    private func adsLoad(
        script: ADSScript,
        requestedTag: UInt16
    ) -> Int {
        let data     = script.bytecode
        let dataSize = data.count
        adsData     = data
        adsDataSize = dataSize

        adsChunks    = []
        adsChunkLocal = nil
        adsTags      = []

        var offset               = 0
        var tagOffset            = 0
        var bookmarkingChunks    = false
        var bookmarkingIfNotRunnings = false

        while offset < dataSize - 1 {
            let opcode = readUInt16LE(data, at: offset)
            offset += 2

            switch opcode {

            case 0x1350:  // IF_LASTPLAYED
                let slot = readUInt16LE(data, at: offset)
                let tag  = readUInt16LE(data, at: offset + 2)
                offset += 4
                if bookmarkingChunks {
                    bookmarkingIfNotRunnings = false
                    adsChunks.append(AdsChunk(slot: slot, tag: tag, offset: offset))
                }

            case 0x1360:  // IF_NOT_RUNNING
                let slot = readUInt16LE(data, at: offset)
                let tag  = readUInt16LE(data, at: offset + 2)
                offset += 4
                if bookmarkingChunks && bookmarkingIfNotRunnings {
                    adsChunks.append(AdsChunk(slot: slot, tag: tag, offset: offset))
                }

            case 0x1370:  // IF_IS_RUNNING
                bookmarkingIfNotRunnings = false
                offset += 4

            case 0x1070: offset += 4; break
            case 0x1330: offset += 4; break
            case 0x1420: break                // AND
            case 0x1430: break                // OR
            case 0x1510: break                // PLAY_SCENE
            case 0x1520: offset += 10; break  // ADD_SCENE_LOCAL (5 words)
            case 0x2005: offset += 8;  break  // ADD_SCENE (4 words)
            case 0x2010: offset += 6;  break  // STOP_SCENE (3 words)
            case 0x2014: break                // undocumented 0 args
            case 0x3010: break                // RANDOM_START
            case 0x3020: offset += 2;  break  // NOP (1 word)
            case 0x30FF: break                // RANDOM_END
            case 0x4000: offset += 6;  break  // UNKNOWN_6 (3 words)
            case 0xF010: break                // FADE_OUT
            case 0xF200: offset += 2;  break  // GOSUB_TAG (1 word)
            case 0xFFFF: break                // END
            case 0xFFF0: break                // END_IF

            default:
                // Tag opcode — any unrecognised uint16 is a scene tag
                let thisTagOffset = offset
                adsTags.append((id: opcode, offset: thisTagOffset))

                if opcode == requestedTag {
                    tagOffset                = thisTagOffset
                    bookmarkingChunks        = true
                    bookmarkingIfNotRunnings = true
                } else {
                    bookmarkingChunks        = false
                    bookmarkingIfNotRunnings = false
                }
            }
        }

        return tagOffset
    }

    // ---------------------------------------------------------------
    // MARK: adsFindTag (for GOSUB_TAG) — ads.c:199–216
    // ---------------------------------------------------------------

    private func adsFindTag(_ tag: UInt16) -> Int {
        adsTags.first(where: { $0.id == tag })?.offset ?? 0
    }

    // ---------------------------------------------------------------
    // MARK: isSceneRunning — ads.c:297–311
    // ---------------------------------------------------------------

    private func isSceneRunning(slot: UInt16, tag: UInt16) -> Bool {
        threads.contains {
            $0.isRunning == 1 && $0.sceneSlot == slot && $0.sceneTag == tag
        }
    }

    // ---------------------------------------------------------------
    // MARK: adsAddScene — ads.c:219–269
    // ---------------------------------------------------------------

    private func adsAddScene(slot: UInt16, tag: UInt16, arg3: UInt16) {
        // Don't add duplicates
        for t in threads where t.isRunning == 1 {
            if t.sceneSlot == slot && t.sceneTag == tag { return }
        }
        // Find a free thread slot
        guard let freeThread = threads.first(where: { $0.isRunning == 0 }) else {
            return
        }

        freeThread.ttmSlot         = ttmSlots[Int(slot)]
        freeThread.isRunning       = 1
        freeThread.sceneSlot       = slot
        freeThread.sceneTag        = tag
        freeThread.sceneTimer      = 0
        freeThread.sceneIterations = 0
        freeThread.delay           = 4
        freeThread.timer           = 0
        freeThread.nextGotoOffset  = 0
        freeThread.selectedBmpSlot = 0
        freeThread.fgColor         = 0x0F
        freeThread.bgColor         = 0x0F
        freeThread.layer           = GraphicsState.newLayer()

        // Resolve slot name up front (used in both the findTag warning and the spawn log).
        let slotName = ttmSlots[Int(slot)].resourceName

        // Find start offset
        if slot == 0 {
            freeThread.ip = 0
        } else {
            if let ip = ttmSlots[Int(slot)].findTag(tag) {
                freeThread.ip = ip
            } else {
                // Tag not found in the TTM — IP falls back to 0 (start of
                // bytecode). This is jc_reborn-compatible (ttmFindTag returns 0
                // when not found), but it means the thread will execute whatever
                // bytecode happens to be at offset 0, which is rarely correct.
                print("[ttm] WARN adsAddScene: tag \(tag) not found in slot \(slot)(\(slotName)) — falling back to ip=0 (bytecodeLen=\(ttmSlots[Int(slot)].bytecode.count))")
                freeThread.ip = 0
            }
        }

        // Interpret arg3 as signed: negative = timer, positive = repeat count
        let arg3s = Int(Int16(bitPattern: arg3))
        if arg3s < 0 {
            freeThread.sceneTimer = -arg3s
        } else if arg3s > 0 {
            freeThread.sceneIterations = arg3s - 1
        }

        numThreads += 1
        let threadIdx = threads.firstIndex(where: { $0 === freeThread }) ?? -1
        print("[thread] spawn idx=\(threadIdx) slot=\(slot)(\(slotName)) tag=\(tag) sceneTimer=\(freeThread.sceneTimer) iter=\(freeThread.sceneIterations) ip=\(freeThread.ip) (numThreads=\(numThreads))")

        // NOTE: do NOT immediately play() the new thread here.
        //
        // We previously did this to mask a one-frame "flicker" gap between
        // sub-scenes (Johnny disappearing for one frame between PURGE-and-
        // free of thread A and the first draw of trigger-spawned thread B).
        // But that immediate play interacted badly with chunk graphs that
        // self-trigger: the new thread could hit PURGE → state 2 → cleanup
        // in the SAME post-process pass, firing the next triggered chunk
        // synchronously and accelerating the chunk-graph cycle so much that
        // some scenes (e.g. STAND.ADS tag=5 cycling MJAMBWLK 41/43/44/65)
        // never terminate naturally.
        //
        // jc_reborn matches our (post-revert) behaviour: spawn does NOT
        // play; the new thread plays in the next scheduler.tick step (b).
        // The proper fix for the flicker is to snapshot composedFramebuffer
        // BEFORE post-process (matching jc_reborn's grUpdateDisplay timing),
        // not to inject an immediate play.
    }

    // ---------------------------------------------------------------
    // MARK: adsStopScene — ads.c:272–277
    // ---------------------------------------------------------------

    private func adsStopScene(_ thread: TTMThread) {
        thread.free()
        numThreads -= 1
    }

    private func adsStopSceneByTtmTag(slot: UInt16, tag: UInt16) {
        for t in threads {
            if t.isRunning != 0 && t.sceneSlot == slot && t.sceneTag == tag {
                adsStopScene(t)
            }
        }
    }

    // ---------------------------------------------------------------
    // MARK: Random-block helpers — ads.c:338–405
    // ---------------------------------------------------------------

    private func randStart() { randOps = [] }

    private func randAddScene(slot: UInt16, tag: UInt16,
                               numPlays: UInt16, weight: UInt16) {
        randOps.append(RandOp(type: .addScene, slot: slot, tag: tag,
                              numPlays: numPlays, weight: weight))
    }

    private func randStopScene(slot: UInt16, tag: UInt16, weight: UInt16) {
        randOps.append(RandOp(type: .stopScene, slot: slot, tag: tag,
                              numPlays: 0, weight: weight))
    }

    private func randNop(weight: UInt16) {
        randOps.append(RandOp(type: .nop, slot: 0, tag: 0,
                              numPlays: 0, weight: weight))
    }

    private func randEnd() {
        guard !randOps.isEmpty else { return }
        let total   = randOps.reduce(0) { $0 + Int($1.weight) }
        let pick    = Int.random(in: 0 ..< total)
        var partial = 0
        for op in randOps {
            partial += Int(op.weight)
            if pick < partial {
                switch op.type {
                case .addScene:
                    adsAddScene(slot: op.slot, tag: op.tag, arg3: op.numPlays)
                case .stopScene:
                    adsStopSceneByTtmTag(slot: op.slot, tag: op.tag)
                case .nop:
                    break
                }
                return
            }
        }
    }

    // ---------------------------------------------------------------
    // MARK: adsPlayChunk — ads.c:445–630
    // ---------------------------------------------------------------

    private func adsPlayChunk(offset startOffset: Int) {
        var offset             = startOffset
        var inRandBlock        = false
        var inOrBlock          = false
        var inSkipBlock        = false
        var inIfLastplayedLocal = false
        var continueLoop       = true

        while continueLoop && offset < adsDataSize - 1 {
            let opcode = readUInt16LE(adsData, at: offset)
            offset += 2

            switch opcode {

            case 0x1070:  // IF_LASTPLAYED_LOCAL
                let slot = readUInt16LE(adsData, at: offset)
                let tag  = readUInt16LE(adsData, at: offset + 2)
                offset += 4
                inIfLastplayedLocal = true
                adsChunkLocal = AdsChunk(slot: slot, tag: tag, offset: offset)

            case 0x1330:  // IF_UNKNOWN_1 (synonym of IF_NOT_RUNNING, ignored)
                offset += 4

            case 0x1350:  // IF_LASTPLAYED
                offset += 4
                if !inOrBlock { continueLoop = false }
                inOrBlock = false

            case 0x1360:  // IF_NOT_RUNNING
                let slot = readUInt16LE(adsData, at: offset)
                let tag  = readUInt16LE(adsData, at: offset + 2)
                offset += 4
                if isSceneRunning(slot: slot, tag: tag) { inSkipBlock = true }

            case 0x1370:  // IF_IS_RUNNING
                let slot = readUInt16LE(adsData, at: offset)
                let tag  = readUInt16LE(adsData, at: offset + 2)
                offset += 4
                // .fixed: Go-port correction (ads.go:417) — skip when NOT running.
                // .raw:   jc_reborn inversion bug — skip when IS running.
                if fidelityMode == .fixed {
                    inSkipBlock = !isSceneRunning(slot: slot, tag: tag)
                } else {
                    inSkipBlock = isSceneRunning(slot: slot, tag: tag)
                }

            case 0x1420:  // AND — no action needed
                break

            case 0x1430:  // OR
                inOrBlock = true

            case 0x1510:  // PLAY_SCENE — close conditional block
                if inSkipBlock {
                    inSkipBlock = false
                } else {
                    continueLoop = false
                }

            case 0x1520:  // ADD_SCENE_LOCAL
                let _ = readUInt16LE(adsData, at: offset)       // skip first arg
                let slot     = readUInt16LE(adsData, at: offset + 2)
                let tag      = readUInt16LE(adsData, at: offset + 4)
                let numPlays = readUInt16LE(adsData, at: offset + 6)
                offset += 10  // 5 words
                if !inIfLastplayedLocal {
                    adsAddScene(slot: slot, tag: tag, arg3: numPlays)
                }
                inIfLastplayedLocal = false

            case 0x2005:  // ADD_SCENE
                let slot     = readUInt16LE(adsData, at: offset)
                let tag      = readUInt16LE(adsData, at: offset + 2)
                let numPlays = readUInt16LE(adsData, at: offset + 4)
                let weight   = readUInt16LE(adsData, at: offset + 6)
                offset += 8
                if !inSkipBlock {
                    if inRandBlock {
                        randAddScene(slot: slot, tag: tag,
                                     numPlays: numPlays, weight: weight)
                    } else {
                        adsAddScene(slot: slot, tag: tag, arg3: numPlays)
                    }
                }

            case 0x2010:  // STOP_SCENE
                let slot   = readUInt16LE(adsData, at: offset)
                let tag    = readUInt16LE(adsData, at: offset + 2)
                let weight = readUInt16LE(adsData, at: offset + 4)
                offset += 6
                if !inSkipBlock {
                    if inRandBlock {
                        randStopScene(slot: slot, tag: tag, weight: weight)
                    } else {
                        adsStopSceneByTtmTag(slot: slot, tag: tag)
                    }
                }

            case 0x3010:  // RANDOM_START
                randStart()
                inRandBlock = true

            case 0x3020:  // NOP (in random block)
                let weight = readUInt16LE(adsData, at: offset)
                offset += 2
                if inRandBlock { randNop(weight: weight) }

            case 0x30FF:  // RANDOM_END
                randEnd()
                inRandBlock = false

            case 0x4000:  // UNKNOWN_6 (BUILDING.ADS tag 7; 3 args, ignored)
                offset += 6

            case 0xF010:  // FADE_OUT — Phase 7
                break

            case 0xF200:  // GOSUB_TAG
                let tag = readUInt16LE(adsData, at: offset)
                offset += 2
                let dest = adsFindTag(tag)
                if dest != 0 {
                    adsPlayChunk(offset: dest)
                }

            case 0xFFFF:  // END
                if inSkipBlock {
                    inSkipBlock = false
                } else {
                    stopRequested = true
                }

            case 0xFFF0:  // END_IF
                break

            default:
                // Tag marker encountered mid-chunk — treat as end of block
                break
            }
        }
    }

    // ---------------------------------------------------------------
    // MARK: adsPlayTriggeredChunks — ads.c:633–655
    // ---------------------------------------------------------------

    private func adsPlayTriggeredChunks(slot: UInt16, tag: UInt16) {
        // Check for local override first (ACTIVITY.ADS tag 7)
        if let local = adsChunkLocal {
            if local.slot == slot && local.tag == tag {
                adsPlayChunk(offset: local.offset)
                adsChunkLocal = nil
                return
            }
        }

        // General case: may be multiple IF_LASTPLAYED for same scene
        for chunk in adsChunks {
            if chunk.slot == slot && chunk.tag == tag {
                adsPlayChunk(offset: chunk.offset)
            }
        }
    }

    // ---------------------------------------------------------------
    // MARK: beginADS — loads slots and fires initial chunk
    // ---------------------------------------------------------------

    func beginADS(script: ADSScript, tag: UInt16) throws {
        // Diagnostic: log any threads still running at reset time.
        // Normally all threads should be free (isRunning=0) before beginADS
        // is called — the scene completed (numThreads→0) and the walk thread
        // was freed before state transitioned to .idle. Seeing this log means
        // a thread survived the scene boundary unexpectedly.
        let liveAtReset = threads.enumerated().filter { $0.element.isRunning != 0 }
        if !liveAtReset.isEmpty {
            let desc = liveAtReset.map { e in
                "idx=\(e.offset) isRunning=\(e.element.isRunning) slot=\(e.element.ttmSlot?.resourceName ?? "nil") tag=\(e.element.sceneTag)"
            }.joined(separator: ", ")
            print("[ads] beginADS tag=\(tag): resetting \(liveAtReset.count) live thread(s): \(desc)")
        }

        // Reset state
        for slot in ttmSlots { slot.reset() }
        for t in threads     { t.free() }
        numThreads        = 0
        stopRequested     = false
        snapshotFramebuffer = nil   // discard prior scene's last snapshot
        // Note: graphics.dx/dy are NOT reset here. jc_reborn's adsPlay() leaves
        // them alone — the caller (story.c / Engine façade) is responsible for
        // setting them to the island offset (or zero for non-island scenes)
        // BEFORE calling beginADS. Resetting here clobbered the island offset
        // StoryRunner had just set, which made every TTM scene render its
        // sprites at (0,0) instead of on the island — i.e. Johnny was being
        // drawn off-screen.
        // Background/holiday are managed externally by StoryRunner; don't reset here.

        // Load each referenced TTM into its slot
        for ref in script.referencedResources {
            let idx = Int(ref.id)
            guard idx < MAX_TTM_SLOTS else { continue }
            let ttmScript = try cache.ttmScript(named: ref.name)
            ttmSlots[idx].load(from: ttmScript, name: ref.name)
        }

        // Scan ADS bytecode and fire the opening chunk
        let offset = adsLoad(script: script, requestedTag: tag)
        stopRequested = false
        adsPlayChunk(offset: offset)
    }

    // ---------------------------------------------------------------
    // MARK: tick() — one iteration of the ADS main loop (ads.c:683–796)
    // ---------------------------------------------------------------

    /// Advance one iteration:
    ///  a) advance all threads whose timer == 0
    ///  b) find mini (minimum timer)
    ///  c) decrement all timers by mini
    ///  d) process finished threads (fire IF_LASTPLAYED, re-queue or stop)
    ///
    /// Returns the number of ticks to sleep (mini).
    @discardableResult
    func tick() -> Int {
        // (0) PRE-TICK SWEEP — catch leaked walk threads BEFORE any of the
        // ads.c logic runs. A walk thread (claimed by StoryRunner.startWalk)
        // has isRunning=1 but ttmSlot=nil; if one of these survives into a
        // scheduler.tick() call (which only happens in .playingScene state),
        // it's an Issue 1 leak. The play() loop in step (b) only iterates
        // `t.timer == 0` threads, so a leaked walk thread with timer>0 (after
        // step c decrements) would persist for an extra tick. Sweeping here
        // is timer-independent and resolves the freeze in the SAME tick the
        // leak is detected, regardless of how the leak happened.
        //
        // Diagnostic: log the leak so we can correlate with surrounding
        // [walk]/[thread]/[story] events and pinpoint the root cause.
        for t in threads where t.isRunning == 1 && (t.ttmSlot == nil || t.ttmSlot?.isLoaded == false) {
            let idx = threads.firstIndex(where: { $0 === t }) ?? -1
            let slotDesc = t.ttmSlot.map { "\($0.resourceName.isEmpty ? "(empty)" : $0.resourceName) isLoaded=\($0.isLoaded)" } ?? "nil"
            print("[ads] WARN: pre-tick sweep freeing leaked nil/unloaded-slot thread idx=\(idx) slot=\(slotDesc) tag=\(t.sceneTag) timer=\(t.timer) delay=\(t.delay) (numThreads before=\(numThreads))")
            t.free()
            numThreads = max(0, numThreads - 1)
        }

        // (a) Advance background thread (island wave animation, ads.c:685–689)
        if backgroundThread.isRunning != 0 && backgroundThread.timer == 0 {
            backgroundThread.timer = backgroundThread.delay
            onBackgroundTick?()
        }

        // (b) Advance foreground threads
        for t in threads where t.isRunning == 1 && t.timer == 0 {
            t.timer = t.delay
            TTMInterpreter.play(
                thread: t, graphics: graphics,
                cache: cache, sound: sound
            )
        }

        // SNAPSHOT for display: capture the framebuffer state HERE, after
        // play() but BEFORE post-process. This matches jc_reborn's
        // grUpdateDisplay timing (ads.c:729 — display is taken before the
        // post-process loop at ads.c:760+ frees state-2 threads and fires
        // triggered chunks). Without this snapshot, our composedFramebuffer
        // is captured AFTER post-process — by which point thread A has
        // already been freed and thread B (its successor) hasn't drawn yet,
        // producing a one-frame "Johnny vanishes" flicker between sub-
        // scenes. With the snapshot, the displayed frame still shows
        // thread A's last draws while triggers spawn B for the next tick.
        snapshotFramebuffer = composeFramebufferNow()

        // (c) Compute mini across background + foreground timers (ads.c:732–747).
        // Iterate all non-zero isRunning states (including 2 = "terminated,
        // awaiting cleanup"); restricting to ==1 left state-2 threads with
        // their timers frozen, so the post-process cleanup never fired and
        // scenes wedged forever (numThreads stayed > 0). Also include `delay`
        // alongside `timer` to match jc_reborn ads.c:741–745.
        var mini = 300
        if backgroundThread.isRunning != 0 {
            mini = min(mini, backgroundThread.timer)
        }
        for t in threads where t.isRunning != 0 {
            if t.delay < mini { mini = t.delay }
            if t.timer < mini { mini = t.timer }
        }
        if mini == 300 { mini = 0 }

        // (d) Decrement timers — also for state-2 threads, otherwise their
        // timer never reaches 0 and the cleanup branch below is never taken.
        if backgroundThread.isRunning != 0 {
            backgroundThread.timer -= mini
        }
        for t in threads where t.isRunning != 0 {
            t.timer -= mini
        }

        // (d) Post-process
        for t in threads where t.isRunning != 0 && t.timer == 0 {
            // Apply scheduled jumps
            if t.nextGotoOffset != 0 {
                t.ip = t.nextGotoOffset
                t.nextGotoOffset = 0
            }

            // Tick down scene duration timer
            if t.sceneTimer > 0 {
                t.sceneTimer -= t.delay
                if t.sceneTimer <= 0 {
                    t.isRunning = 2
                }
            }

            // Process done threads
            if t.isRunning == 2 {
                let idx = threads.firstIndex(where: { $0 === t }) ?? -1
                let slotName = t.ttmSlot?.resourceName ?? "?"
                if t.sceneIterations > 0 {
                    print("[thread] requeue idx=\(idx) slot=\(slotName) tag=\(t.sceneTag) iterRemaining=\(t.sceneIterations - 1)")
                    t.sceneIterations -= 1
                    t.isRunning = 1
                    if let ip = ttmSlots[Int(t.sceneSlot)].findTag(t.sceneTag) {
                        t.ip = ip
                    } else {
                        print("[ttm] WARN requeue: tag \(t.sceneTag) not found in slot \(slotName) — falling back to ip=0")
                        t.ip = 0
                    }
                    // No layer clear here — match jc_reborn. The stacked-
                    // sprite trails this was added to fix were actually
                    // caused by the (now-fixed) tag scanner and DRAW_SPRITE
                    // imageNo bugs, not by missing iteration-clear.
                    // Clearing here causes a single-frame flicker at the
                    // boundary of every iteration (layer goes empty until
                    // the iteration's first opcodes draw something).
                } else {
                    print("[thread] free idx=\(idx) slot=\(slotName) tag=\(t.sceneTag) (numThreads=\(numThreads - 1))")
                    let doneSlot = t.sceneSlot
                    let doneTag  = t.sceneTag
                    adsStopScene(t)
                    if !stopRequested {
                        adsPlayTriggeredChunks(slot: doneSlot, tag: doneTag)
                    }
                }
            }
        }

        return mini
    }
}
