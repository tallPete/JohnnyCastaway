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

    /// Composed output for the current frame.
    /// Order: background → active TTM layers → holiday decoration.
    var composedFramebuffer: Framebuffer {
        var dest = Framebuffer()
        let activeLayers = threads.filter { $0.isRunning == 1 }.map { $0.layer }
        graphics.composite(threadLayers: activeLayers, into: &dest)
        if let holiday = holidayLayer {
            dest.composite(layer: holiday)
        }
        return dest
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

        // Find start offset
        if slot == 0 {
            freeThread.ip = 0
        } else {
            freeThread.ip = ttmSlots[Int(slot)].findTag(tag) ?? 0
        }

        // Interpret arg3 as signed: negative = timer, positive = repeat count
        let arg3s = Int(Int16(bitPattern: arg3))
        if arg3s < 0 {
            freeThread.sceneTimer = -arg3s
        } else if arg3s > 0 {
            freeThread.sceneIterations = arg3s - 1
        }

        numThreads += 1
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

            case 0x1370:  // IF_IS_RUNNING (corrected: skip if NOT running)
                let slot = readUInt16LE(adsData, at: offset)
                let tag  = readUInt16LE(adsData, at: offset + 2)
                offset += 4
                // Fix per Go port (ads.go:417): inSkipBlock = !isSceneRunning
                inSkipBlock = !isSceneRunning(slot: slot, tag: tag)

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
        // Reset state
        for slot in ttmSlots { slot.reset() }
        for t in threads     { t.free() }
        numThreads        = 0
        stopRequested     = false
        graphics.dx       = 0
        graphics.dy       = 0
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

        // (c) Compute mini across background + foreground timers (ads.c:732–747)
        var mini = 300
        if backgroundThread.isRunning != 0 {
            mini = min(mini, backgroundThread.timer)
        }
        for t in threads where t.isRunning == 1 {
            if t.timer < mini { mini = t.timer }
        }
        if mini == 300 { mini = 0 }

        // (d) Decrement timers
        if backgroundThread.isRunning != 0 {
            backgroundThread.timer -= mini
        }
        for t in threads where t.isRunning == 1 {
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
                if t.sceneIterations > 0 {
                    // Re-queue
                    t.sceneIterations -= 1
                    t.isRunning = 1
                    t.ip = ttmSlots[Int(t.sceneSlot)].findTag(t.sceneTag) ?? 0
                } else {
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
