// JohnnyScreenSaverView.swift
//
// The ScreenSaverView subclass loaded by macOS's legacyScreenSaver
// host process. Each connected display gets its own instance with its
// own engine + renderer; we deliberately do NOT share state across
// instances so multi-display works without cross-screen sync.
//
// Lifecycle (Sonoma-aware):
//   • init(frame:isPreview:) — set up CAMetalLayer backing, defaults
//   • startAnimation()       — load resources, kick off engine
//   • animateOneFrame()      — pace engine ticks, render to drawable
//   • viewDidMoveToWindow(nil) — TEAR DOWN renderer & engine. macOS 14+
//     stopAnimation() is unreliable; relying on it leaks the
//     legacyScreenSaver process at high CPU after dismissal.
//
// Resource onboarding: the user picks a folder via the configure sheet
// or the first-run floating panel.  The configure sheet (System Settings)
// stores only a plain path (used for the display label).  The first-run
// panel runs inside legacyScreenSaver, so its NSOpenPanel result carries
// the right sandbox context; save(folder:) creates a security-scoped
// bookmark that persists across launches.  See ResourceFolder.swift.

import ScreenSaver
import AppKit
import Metal
import QuartzCore
import JohnnyResources
import JohnnyEngine
import JohnnyMetalRenderer

/// Fires once when the dylib is dlopened by the host. Lets us prove
/// the bundle loaded (in System Settings or legacyScreenSaver) before
/// any class methods are touched.
private let _bundleLoadMarker: Void = {
    NSLog("[Johnny] dylib loaded by %@", ProcessInfo.processInfo.processName)
}()

@objc(JohnnyScreenSaverView)
public final class JohnnyScreenSaverView: ScreenSaverView {

    // ---------------------------------------------------------------
    // MARK: Engine state (per-instance — never shared across displays)
    // ---------------------------------------------------------------

    private var renderer:    EngineRenderer?
    private var storyRunner: StoryRunner?
    private var rng          = SystemRandomNumberGenerator()
    private var soundSink: SoundSink = NullSoundSink()

    /// Wall-clock time of the last engine tick. Used to pace ticks
    /// against the engine's `mini` value (×20 ms per tick — see
    /// jc_reborn events.c:108).
    private var lastTickWall: CFTimeInterval = 0

    /// Minimum wall-clock interval (ms) between engine ticks, derived
    /// from the previous tick's `mini` return. Floored at 4 so we
    /// never spin at display refresh rate when the engine reports 0.
    private var lastMiniMS: Int = 4

    /// Animation-speed multiplier captured at startup (settings sheet).
    /// 1.0 = faithful pacing; 2.0 doubles speed; 0.5 halves it.
    private var animationSpeed: Double = 1.0

    // ---- Debug overlay (only created when ResourceFolder.debugOverlayEnabled) ----

    /// HUD displayed in the top-left when the user enables "Show debug overlay"
    /// in the configure sheet.  Native AppKit (NSTextField) — avoids the
    /// SwiftUI / EngineDebugState plumbing that the saver doesn't otherwise need.
    private var debugOverlay: NSTextField?

    /// Frame counter and timestamp used for the overlay's FPS readout.
    private var debugFrameCount:    Int            = 0
    private var debugLastFPSTime:   CFTimeInterval = 0
    private var debugLastFPS:       Double         = 0

    /// Reason the engine isn't running, surfaced for the idle frame.
    private enum LoadState {
        case notLoaded
        case loaded
        case error(String)
    }
    private var loadState: LoadState = .notLoaded

    /// True once we have scheduled (or shown) the first-run resource
    /// picker panel. Prevents re-presenting on every startAnimation call
    /// (the preview pane can call startAnimation many times).
    private var didScheduleResourcePicker = false

    // ---- Tahoe runaway-host defenses --------------------------------
    //
    // On macOS 14+ (and especially Tahoe), legacyScreenSaver routinely
    // fails to terminate after the user dismisses the screensaver: the
    // standard ScreenSaverView lifecycle callbacks (stopAnimation,
    // viewDidMoveToWindow(nil), viewWillMove(toSuperview:nil)) often
    // never fire.  The host process keeps ticking the engine in the
    // background, AVAudioPlayer keeps queueing sounds, and CGEventTaps
    // installed by AppKit can interfere with the user's mouse.
    //
    // We defend with two complementary mechanisms:
    //
    //  1. A distributed-notification subscription on
    //     "com.apple.screensaver.didstop" — this fires on real
    //     dismissal even when the view callbacks don't.
    //
    //  2. A watchdog DispatchWorkItem armed in stopAnimation that
    //     calls exit(0) after 8s of no startAnimation, BUT only when
    //     processName == "legacyScreenSaver" AND the view was full-
    //     screen at last startAnimation.  System Settings preview
    //     pauses fire stopAnimation too, so a naive watchdog would
    //     kill the preview process.

    private static let isInLegacyScreenSaver: Bool = {
        ProcessInfo.processInfo.processName.lowercased().contains("legacyscreensaver")
    }()

    /// True if the most recent startAnimation was on a full-screen sized
    /// window.  Gates the exit watchdog so System Settings preview is never
    /// killed (preview windows are typically <800px wide).
    private var wasFullScreenAtStart: Bool = false

    /// Pending watchdog that calls exit(0) if the host doesn't terminate
    /// us within a reasonable window after dismissal.  Cancelled by the
    /// next startAnimation() call.
    private var emergencyExitWork: DispatchWorkItem? = nil

    /// Cached so we can unsubscribe in deinit (best-effort).
    private var didStopObserver: NSObjectProtocol? = nil

    // (Polling-based zombie detection was removed — see animateOneFrame.)

    /// Our parent PID captured at init.  When the screensaver's host
    /// process dies, the kernel reparents us to launchd (PID 1).  A
    /// `getppid()` change is therefore a reliable, kernel-level signal
    /// that we've been orphaned — unlike NSWindow.occlusionState, this
    /// can't be lied to by the ViewBridge service architecture.
    private var originalParentPID: pid_t = 1

    /// Frame counter for the orphan poll (~1 s at 30 Hz).
    private var orphanCheckCounter: Int = 0
    private let orphanCheckInterval: Int = 30

    // ---------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------

    public override init?(frame: NSRect, isPreview: Bool) {
        _ = _bundleLoadMarker
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        // ScreenSaverView's animationTimeInterval is the cadence at
        // which animateOneFrame() is called. We pace internally
        // anyway, so a high cadence (1/30 s) is fine.
        animationTimeInterval = 1.0 / 30.0
        originalParentPID = getppid()
        NSLog("[Johnny] init(frame:isPreview:) preview=%d process=%@ parentPID=%d",
              isPreview ? 1 : 0, ProcessInfo.processInfo.processName, originalParentPID)
        installDismissalObservers()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        animationTimeInterval = 1.0 / 30.0
        originalParentPID = getppid()
        NSLog("[Johnny] init(coder:) parentPID=%d", originalParentPID)
        installDismissalObservers()
    }

    // ---------------------------------------------------------------
    // MARK: CAMetalLayer backing
    // ---------------------------------------------------------------

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat        = .bgra8Unorm
        layer.framebufferOnly    = true
        layer.backgroundColor    = CGColor.black
        layer.displaySyncEnabled = true
        return layer
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.drawableSize = convertToBacking(bounds.size)
        }
    }

    // ---------------------------------------------------------------
    // MARK: Animation lifecycle
    // ---------------------------------------------------------------

    public override func startAnimation() {
        // Cancel any pending emergency-exit watchdog from a prior
        // stopAnimation — System Settings preview pauses fire
        // start/stop pairs in rapid succession, and we don't want the
        // watchdog to kill us during one of those cycles.
        emergencyExitWork?.cancel()
        emergencyExitWork = nil

        // Capture window size to gate the exit watchdog: only kill the
        // process if we WERE running full-screen.  Preview windows are
        // small (typically < 800 px wide) and Settings keeps them
        // installed for as long as the panel is open.
        if let w = window {
            wasFullScreenAtStart = (w.frame.width >= 800 && w.frame.height >= 600)
        } else {
            wasFullScreenAtStart = false
        }
        NSLog("[Johnny] startAnimation: wasFullScreenAtStart=%d windowSize=%@",
              wasFullScreenAtStart ? 1 : 0,
              NSStringFromSize(window?.frame.size ?? .zero))

        super.startAnimation()
        startupIfNeeded()

        // First-run / error-recovery onboarding: if the engine didn't
        // start (no folder configured, or archive failed to load), show
        // the resource-picker panel.
        //
        // We intentionally do NOT gate on !isPreview: on macOS 26 Tahoe
        // isPreview can be true even for full-screen activation (a known
        // Sequoia-era regression), so filtering on it silently suppresses
        // the dialog for everyone.  The didScheduleResourcePicker flag
        // already prevents repeated presentation on rapid start/stop cycles.
        let needsOnboarding: Bool = {
            switch loadState {
            case .notLoaded, .error: return true
            case .loaded:            return false
            }
        }()
        NSLog("[Johnny] startAnimation: isPreview=%d loadState=%@ needsOnboarding=%d",
              isPreview ? 1 : 0,
              { switch loadState { case .notLoaded: return "notLoaded"
                                   case .loaded:    return "loaded"
                                   case .error(let e): return "error(\(e))" } }(),
              needsOnboarding ? 1 : 0)

        if needsOnboarding, !didScheduleResourcePicker {
            didScheduleResourcePicker = true
            DispatchQueue.main.async { [weak self] in
                self?.presentResourcePickerIfNeeded()
            }
        }
    }

    public override func stopAnimation() {
        super.stopAnimation()
        // Silence audio synchronously every time stopAnimation fires.
        //
        // We intentionally do NOT tear down the engine / Metal here —
        // viewDidMoveToWindow(nil) is the reliable teardown point on
        // macOS 14+, and stopAnimation can fire repeatedly when the
        // System Settings preview pane pauses.  But AVAudioPlayer
        // keeps audio in a hardware buffer that survives object release,
        // so silencing it on every stopAnimation is the only way to
        // guarantee sound stops the instant the user dismisses the
        // screensaver — even if the view-removal callbacks lag.
        soundSink.stopAll()
        NSLog("[Johnny] stopAnimation: audio silenced")

        // Arm the runaway-host watchdog (gated by process name and
        // full-screen mode — see scheduleEmergencyExitIfNeeded).
        scheduleEmergencyExitIfNeeded()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // Sonoma+ workaround: stopAnimation() doesn't fire
            // reliably when the screensaver dismisses. Tear down
            // explicitly when the view leaves the window so the
            // legacyScreenSaver process drops to ~0% CPU.
            teardown()
        }
    }

    public override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            teardown()
        }
    }

    // ---------------------------------------------------------------
    // MARK: Startup
    // ---------------------------------------------------------------

    private func startupIfNeeded() {
        guard renderer == nil else {
            NSLog("[Johnny] startupIfNeeded: already running, skipping")
            return
        }

        NSLog("[Johnny] startupIfNeeded: starting — process=%@",
              ProcessInfo.processInfo.processName)

        // 1. Metal device + renderer
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("[Johnny] startupIfNeeded: no Metal device")
            loadState = .error("No Metal device")
            return
        }
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.device       = device
            metalLayer.drawableSize = convertToBacking(bounds.size)
        }
        do {
            renderer = try EngineRenderer(device: device)
            NSLog("[Johnny] startupIfNeeded: renderer created")
        } catch {
            NSLog("[Johnny] startupIfNeeded: renderer error — %@", error.localizedDescription)
            loadState = .error("Renderer: \(error.localizedDescription)")
            return
        }

        // 2. Resolve user's resource folder from stored path
        guard let folder = ResourceFolder.resolve() else {
            NSLog("[Johnny] startupIfNeeded: no resource folder — showing idle frame")
            loadState = .notLoaded
            return
        }

        // 3. Sound sink — create before the StoryRunner so the sink's
        //    AVAudioPlayers are preloaded from the same folder.
        if ResourceFolder.soundEnabled {
            soundSink = AVAudioPlayerSoundSink(folder: folder)
            NSLog("[Johnny] startupIfNeeded: sound ON")
        } else {
            soundSink = NullSoundSink()
            NSLog("[Johnny] startupIfNeeded: sound OFF")
        }

        // 4. Parse archive + spin up StoryRunner
        do {
            let mapURL       = folder.appendingPathComponent("RESOURCE.MAP")
            let containerURL = folder.appendingPathComponent("RESOURCE.001")
            NSLog("[Johnny] startupIfNeeded: loading archive from %@", folder.path)
            let mapData       = try Data(contentsOf: mapURL)
            let containerData = try Data(contentsOf: containerURL)
            let archive = try ResourceArchive.parse(map: mapData, container: containerData)
            NSLog("[Johnny] startupIfNeeded: archive parsed OK")

            // Apply configure-sheet settings (§2.4):
            //
            // • Force Holiday: if non-zero, the StoryRunner sees a synthesised
            //   date inside the holiday window so SceneScheduler.holiday()
            //   triggers the matching decoration.
            // • Force Story Day: post-init override on StoryRunner's
            //   forceStoryDay, applied to every beginNextSequence call.
            // • Fidelity Mode: post-init property on StoryRunner.
            // • Animation Speed: cached for animateOneFrame pacing.
            let holidayCode = ResourceFolder.forceHoliday
            let dateProvider: DateProvider = {
                if let forced = ResourceFolder.dateForForcedHoliday(holidayCode) {
                    NSLog("[Johnny] startupIfNeeded: forcing holiday=%d (date=%@)",
                          holidayCode, "\(forced)")
                    return FixedDateProvider(forced)
                }
                return SystemDateProvider()
            }()

            let runner = try StoryRunner(
                archive:      archive,
                dateProvider: dateProvider,
                sound:        soundSink
            )
            runner.fidelityMode = ResourceFolder.fidelityMode
            let forcedDay = ResourceFolder.forceStoryDay
            runner.forceStoryDay = (forcedDay > 0) ? forcedDay : nil
            self.animationSpeed  = ResourceFolder.animationSpeed
            NSLog("[Johnny] startupIfNeeded: settings — fidelity=%@ forceDay=%d speed=%.2f overlay=%d",
                  runner.fidelityMode.rawValue,
                  forcedDay,
                  self.animationSpeed,
                  ResourceFolder.debugOverlayEnabled ? 1 : 0)

            NSLog("[Johnny] startupIfNeeded: StoryRunner created — engine is live")
            self.storyRunner  = runner
            self.loadState    = .loaded
            self.lastTickWall = CACurrentMediaTime()

            // Install the debug HUD if enabled.
            if ResourceFolder.debugOverlayEnabled {
                installDebugOverlay()
            } else {
                removeDebugOverlay()
            }
        } catch {
            NSLog("[Johnny] startupIfNeeded: archive/engine error — %@", error.localizedDescription)
            loadState = .error("Resources: \(error.localizedDescription)")
        }
    }

    // ---------------------------------------------------------------
    // MARK: First-run resource picker (Option B fallback)
    // ---------------------------------------------------------------
    //
    // Called asynchronously from startAnimation when the engine couldn't
    // start because no resource folder has been configured. This is the
    // fallback path for macOS 26 Tahoe where System Settings no longer
    // contacts the .saver bundle for its configure sheet.
    //
    // We present a floating NSPanel at window level .floating (above the
    // screensaver view), then attach the NSOpenPanel as a *sheet* on that
    // panel so it inherits the correct z-order and doesn't slip behind
    // other windows.

    @MainActor
    private func presentResourcePickerIfNeeded() {
        // Skip the panel only if the engine actually loaded.  We deliberately
        // do NOT call ResourceFolder.resolve() here — on macOS 26 Tahoe the
        // legacyScreenSaver sandbox allows stat() but blocks open() on
        // ~/Documents, so fileExists() returns true and resolve() returns a
        // non-nil URL even when Data(contentsOf:) will fail.  Using loadState
        // avoids that false-positive and ensures the panel is always shown
        // when the engine hasn't come up.
        if case .loaded = loadState {
            NSLog("[Johnny] presentResourcePickerIfNeeded: engine loaded — skipping panel")
            return
        }

        NSLog("[Johnny] presentResourcePickerIfNeeded: showing setup panel (loadState=%@)",
              { switch loadState { case .notLoaded:     return "notLoaded"
                                   case .loaded:        return "loaded"
                                   case .error(let e): return "error(\(e))" } }())

        // ---- Informational panel ----------------------------------------

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Johnny Castaway — Setup"
        panel.isReleasedWhenClosed = false
        // Must be above the screensaver window (NSWindow.Level.screenSaver = 1000).
        // .floating (level 3) is hidden behind it during full-screen activation.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.center()

        let content = panel.contentView!

        let heading = NSTextField(labelWithString: "Sierra Resource Files Required")
        heading.font = .boldSystemFont(ofSize: 14)
        heading.frame = NSRect(x: 20, y: 156, width: 440, height: 20)
        content.addSubview(heading)

        let body = NSTextField(wrappingLabelWithString:
            "Johnny Castaway requires the original Sierra resource files to run. "
          + "Click \u{201C}Choose Folder\u{2026}\u{201D} and select the folder that "
          + "contains RESOURCE.MAP and RESOURCE.001.\n\n"
          + "If you\u{2019}ve already set this in Screen Saver Options, "
          + "select the same folder again \u{2014} macOS requires it to grant access."
        )
        body.frame = NSRect(x: 20, y: 76, width: 440, height: 72)
        content.addSubview(body)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.frame = NSRect(x: 20, y: 56, width: 440, height: 16)
        content.addSubview(statusLabel)

        // Keep a strong reference for the lifetime of the handler closures.
        let panelRef = panel

        let chooseButton = NSButton(
            title: "Choose Folder…",
            target: nil,
            action: nil
        )
        chooseButton.bezelStyle = .rounded
        chooseButton.frame = NSRect(x: 20, y: 16, width: 140, height: 32)
        content.addSubview(chooseButton)

        let cancelButton = NSButton(
            title: "Cancel",
            target: nil,
            action: nil
        )
        cancelButton.bezelStyle  = .rounded
        cancelButton.frame = NSRect(x: 360, y: 16, width: 100, height: 32)
        content.addSubview(cancelButton)

        // ---- Button handlers -------------------------------------------
        // Capture self weakly to avoid a retain cycle.

        let chooseClosure: @Sendable @MainActor () -> Void = { [weak self] in
            let openPanel = NSOpenPanel()
            openPanel.message                 = "Select the folder containing RESOURCE.MAP and RESOURCE.001"
            openPanel.prompt                  = "Choose"
            openPanel.canChooseFiles          = false
            openPanel.canChooseDirectories    = true
            openPanel.allowsMultipleSelection = false

            // Pre-navigate to the stored path's parent directory so the
            // user can find their folder immediately without navigating.
            // (Opening *inside* the target folder would require the user
            // to go up one level to select it, so we use the parent.)
            if let storedPath = ResourceFolder.displayPath {
                openPanel.directoryURL = URL(fileURLWithPath: storedPath)
                    .deletingLastPathComponent()
            }

            // Present as a sheet attached to our floating panel so it
            // inherits the .floating window level and can't slip behind
            // other windows.
            openPanel.beginSheetModal(for: panelRef) { [weak self] response in
                guard response == .OK, let url = openPanel.url else { return }
                NSLog("[Johnny] openPanel chose: %@", url.path)
                do {
                    try ResourceFolder.save(folder: url)
                    panelRef.close()
                    self?.resetAndStartup()
                } catch {
                    NSLog("[Johnny] openPanel save error: %@", error.localizedDescription)
                    statusLabel.stringValue = error.localizedDescription
                }
            }
        }

        let cancelClosure: @Sendable @MainActor () -> Void = {
            NSLog("[Johnny] setup panel cancelled")
            panelRef.close()
        }

        // Wrap closures in shim targets so AppKit can call them.
        let chooseTarget = ClosureTarget(closure: chooseClosure)
        let cancelTarget = ClosureTarget(closure: cancelClosure)

        chooseButton.target = chooseTarget
        chooseButton.action = #selector(ClosureTarget.invoke)
        cancelButton.target = cancelTarget
        cancelButton.action = #selector(ClosureTarget.invoke)

        // Retain the targets for the panel's lifetime via associated objects.
        objc_setAssociatedObject(panel, &assocKeyChooseTarget, chooseTarget, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(panel, &assocKeyCancelTarget, cancelTarget, .OBJC_ASSOCIATION_RETAIN)

        panel.makeKeyAndOrderFront(nil)
    }

    // ---------------------------------------------------------------
    // MARK: Reset + restart helper
    // ---------------------------------------------------------------

    /// Reset engine state so `startupIfNeeded()` will re-run.
    /// Used after the user configures the resource folder at runtime.
    private func resetAndStartup() {
        NSLog("[Johnny] resetAndStartup")
        renderer    = nil
        storyRunner = nil
        startupIfNeeded()
    }

    // ---------------------------------------------------------------
    // MARK: Teardown (Sonoma-reliable)
    // ---------------------------------------------------------------

    private func teardown() {
        NSLog("[Johnny] teardown — loadState was %@",
              { switch loadState { case .notLoaded: return "notLoaded"
                                   case .loaded:    return "loaded"
                                   case .error(let e): return "error(\(e))" } }())
        // Detach Metal *before* releasing the renderer so the GPU
        // command queue drains.  Without this, CAMetalLayer keeps
        // submitting frames in the background even after our
        // EngineRenderer is gone.
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.device = nil
        }
        renderer    = nil
        storyRunner = nil
        soundSink.stopAll()             // halt in-flight audio before releasing
        soundSink   = NullSoundSink()   // drop AVAudioPlayer instances
        ResourceFolder.stopAccessing()  // release security-scoped sandbox token
        removeDebugOverlay()
        // If we never successfully loaded, allow the picker to reappear
        // next time startAnimation fires (e.g. user dismisses screensaver
        // then re-triggers the hot corner without ever having configured).
        if case .loaded = loadState { } else {
            didScheduleResourcePicker = false
        }
    }

    // ---------------------------------------------------------------
    // MARK: Per-frame
    // ---------------------------------------------------------------

    public override func animateOneFrame() {
        // Orphan detection.
        //
        // Tahoe sometimes leaks our process: the host that spawned us
        // (System Settings preview pane, WallpaperLegacyExtension,
        // loginwindow for full-screen, etc.) exits without telling us,
        // and we keep ticking in the background reparented to launchd.
        //
        // The kernel-level signal is rock-solid: getppid() changes from
        // our spawning host's PID to 1 (launchd) when our parent dies.
        // We can't lie to ourselves about this the way the ViewBridge
        // window can lie about occlusion state.  Polled once a second
        // because syscalls are cheap.
        //
        // Gate by isInLegacyScreenSaver so this never runs in the
        // configure sheet (which is hosted in System Settings, where
        // a parent change would mean something else entirely).
        orphanCheckCounter += 1
        if orphanCheckCounter >= orphanCheckInterval {
            orphanCheckCounter = 0
            if Self.isInLegacyScreenSaver && originalParentPID > 1 {
                let nowParent = getppid()
                if nowParent != originalParentPID {
                    NSLog("[Johnny] orphan detected: parent %d → %d (launchd) — exit(0)",
                          originalParentPID, nowParent)
                    soundSink.stopAll()
                    teardown()
                    exit(0)
                }
            }
        }

        guard let metalLayer = layer as? CAMetalLayer,
              let renderer   = renderer else { return }

        // Pace engine ticks against the previous tick's `mini`, scaled by
        // the user's animation-speed multiplier.  Higher multiplier =>
        // shorter wall-clock interval between ticks => faster animation.
        if let runner = storyRunner {
            let now       = CACurrentMediaTime()
            let elapsedMS = (now - lastTickWall) * 1000.0
            if elapsedMS >= Double(lastMiniMS) {
                do {
                    if runner.sequenceFinished {
                        try runner.beginNextSequence(rng: &rng)
                    }
                    let mini = try runner.tick(rng: &rng)
                    let scaledMS = Double(mini * 20) / max(0.1, animationSpeed)
                    lastMiniMS   = max(4, Int(scaledMS.rounded()))
                    lastTickWall = now
                    renderer.update(framebuffer: runner.composedFramebuffer,
                                    palette:    runner.palette)
                } catch {
                    NSLog("[Johnny] animateOneFrame tick error: %@", error.localizedDescription)
                    loadState = .error("Tick: \(error.localizedDescription)")
                }
            }
        }
        // (If no story runner, the framebuffer was either never
        // updated or holds the last good frame — render anyway so the
        // display stays alive.)

        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer.render(to: drawable, drawableSize: metalLayer.drawableSize)

        // Update the debug HUD (cheap; only allocates a string once per frame).
        if debugOverlay != nil { updateDebugOverlay() }
    }

    // ---------------------------------------------------------------
    // MARK: Tahoe runaway-host defenses
    // ---------------------------------------------------------------

    /// Subscribe to the distributed notification the system posts when a
    /// screensaver session ends.  Reliable on Tahoe even when the
    /// ScreenSaverView callbacks (stopAnimation / viewDidMoveToWindow)
    /// don't fire.  Idempotent — only attaches once per instance.
    private func installDismissalObservers() {
        guard didStopObserver == nil else { return }
        didStopObserver = DistributedNotificationCenter.default().addObserver(
            forName:   NSNotification.Name("com.apple.screensaver.didstop"),
            object:    nil,
            queue:     .main
        ) { [weak self] _ in
            guard let self else { return }
            NSLog("[Johnny] received com.apple.screensaver.didstop")
            self.teardown()
            self.scheduleEmergencyExitIfNeeded()
        }
    }

    /// Arm a one-shot watchdog: if we're still alive in 8 s and no
    /// startAnimation has cancelled it, the host has leaked us — call
    /// exit(0) so audio/CPU stop and the user's mouse works again.
    ///
    /// Strict gating prevents accidental termination of the System
    /// Settings preview process:
    ///   • processName must contain "legacyScreenSaver"
    ///   • the most recent startAnimation must have been on a window
    ///     ≥ 800×600 (full-screen, not preview)
    private func scheduleEmergencyExitIfNeeded() {
        guard Self.isInLegacyScreenSaver else { return }
        guard wasFullScreenAtStart else {
            NSLog("[Johnny] watchdog: skipped (not full-screen)")
            return
        }
        emergencyExitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSLog("[Johnny] watchdog: forcing exit(0) — host failed to terminate")
            // Best-effort final teardown so any in-flight audio is killed
            // before exit() pulls the rug.
            self?.teardown()
            // CFRunLoopStop won't help — the runloop will just be re-entered.
            // exit(0) is the only reliable termination from inside a leaked
            // legacyScreenSaver host.
            exit(0)
        }
        emergencyExitWork = work
        // 8 s window leaves room for a legitimate stop/start preview-pane
        // cycle (the cycle is normally < 1 s).  If a real dismissal
        // happened, no startAnimation will follow and the work item fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)
        NSLog("[Johnny] watchdog: armed (8s) — will exit if no startAnimation")
    }

    // No deinit — JohnnyScreenSaverView is rarely deallocated on Tahoe
    // (legacyScreenSaver leaks the view), and the distributed-notification
    // observer captures `self` weakly so a stale self is harmless.  The
    // host process eventually dying (either naturally or via our exit
    // watchdog) reclaims everything.

    // ---------------------------------------------------------------
    // MARK: Debug overlay (HUD)
    // ---------------------------------------------------------------
    //
    // Native AppKit text label pinned to the top-left.  Shown only when
    // ResourceFolder.debugOverlayEnabled is true.  This is intentionally
    // simpler than the SwiftUI DebugOverlayView from JohnnyDebug — the
    // saver doesn't host an `Engine` (only `StoryRunner`), so the full
    // EngineDebugState wiring would add code without unique value here.

    private func installDebugOverlay() {
        guard debugOverlay == nil else { return }
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        label.drawsBackground = true
        label.alignment = .left
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 0   // multi-line
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16),
        ])
        debugOverlay      = label
        debugFrameCount   = 0
        debugLastFPSTime  = CACurrentMediaTime()
        debugLastFPS      = 0
        NSLog("[Johnny] debug overlay installed")
    }

    private func removeDebugOverlay() {
        debugOverlay?.removeFromSuperview()
        debugOverlay = nil
    }

    /// Refresh the HUD text using the StoryRunner diagnostics.
    /// Called once per `animateOneFrame` when the overlay is installed.
    private func updateDebugOverlay() {
        guard let label = debugOverlay else { return }
        debugFrameCount += 1
        let now = CACurrentMediaTime()
        let dt  = now - debugLastFPSTime
        if dt >= 0.5 {
            debugLastFPS     = Double(debugFrameCount) / dt
            debugFrameCount  = 0
            debugLastFPSTime = now
        }

        let runner    = storyRunner
        let lastSamp  = (soundSink as? AVAudioPlayerSoundSink)?.lastSampleID
        let day       = runner?.storyDay ?? 0
        let active    = runner?.activeThreadCount ?? 0
        let allocated = runner?.allocatedThreadCount ?? 0
        let opcodes   = runner?.coveredTTMOpcodes.count ?? 0
        let fidelity  = runner?.fidelityMode.rawValue ?? "—"
        let holiday   = ResourceFolder.forceHoliday
        let holidayLabel: String = {
            switch holiday {
            case 1: return "Halloween"
            case 2: return "St Patrick"
            case 3: return "Christmas"
            case 4: return "New Year"
            default: return "auto"
            }
        }()

        let text = """
        Johnny Castaway — debug
        day:       \(day)\(runner?.forceStoryDay != nil ? " (forced)" : "")
        threads:   \(active)/\(allocated) active
        opcodes:   \(opcodes) covered
        fidelity:  \(fidelity)
        holiday:   \(holidayLabel)
        speed:     \(String(format: "%.1f×", animationSpeed))
        last snd:  \(lastSamp.map(String.init) ?? "—")
        fps:       \(String(format: "%.1f", debugLastFPS))
        """
        label.stringValue = text
    }

    // ---------------------------------------------------------------
    // MARK: Configuration sheet
    // ---------------------------------------------------------------

    @objc public override var hasConfigureSheet: Bool {
        NSLog("[Johnny] hasConfigureSheet -> true")
        return true
    }

    @objc public override var configureSheet: NSWindow? {
        NSLog("[Johnny] configureSheet getter called")
        let win = ConfigureSheetController.shared.window
        NSLog("[Johnny] configureSheet returning window=%@ visible=%d",
              String(describing: win), win.isVisible ? 1 : 0)
        return win
    }
}

// ---------------------------------------------------------------------------
// MARK: - ClosureTarget
//
// A minimal Objective-C-compatible shim that lets us use a Swift closure as
// the `target` of an NSButton.  AppKit's target/action mechanism requires
// the target to respond to the selector via the ObjC runtime, which plain
// Swift closures don't support.
// ---------------------------------------------------------------------------

@MainActor
private final class ClosureTarget: NSObject {
    private let closure: @MainActor () -> Void
    init(closure: @escaping @MainActor () -> Void) { self.closure = closure }
    @objc func invoke() { closure() }
}

// ---------------------------------------------------------------------------
// MARK: - Associated-object keys
//
// objc_setAssociatedObject requires a stable UnsafeRawPointer key.
// The canonical Swift pattern is a file-scope `nonisolated(unsafe) var`
// whose address is stable for the process lifetime.  Swift 6 strict
// concurrency requires the `nonisolated(unsafe)` annotation.
// ---------------------------------------------------------------------------

private nonisolated(unsafe) var assocKeyChooseTarget: UInt8 = 0
private nonisolated(unsafe) var assocKeyCancelTarget: UInt8 = 0
