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
// Resource onboarding: the user picks a folder via the configure
// sheet or the first-run floating panel; we store the plain path in
// ScreenSaverDefaults(forModuleWithName:).  See ResourceFolder.swift.
// We intentionally avoid security-scoped bookmarks because they are
// sandbox-scoped to the creating process and cannot be resolved in
// legacyScreenSaver (a separate sandbox container).

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
        NSLog("[Johnny] init(frame:isPreview:) preview=%d", isPreview ? 1 : 0)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        animationTimeInterval = 1.0 / 30.0
        NSLog("[Johnny] init(coder:)")
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
        super.startAnimation()
        startupIfNeeded()

        // Belt-and-suspenders first-run onboarding: if there's still no
        // resource folder after startup (System Settings never called our
        // configure sheet — a known regression on macOS 26 Tahoe), present
        // a floating resource-picker panel directly from the saver.
        //
        // Guard: skip in preview (the preview pane resizes/restarts often)
        // and skip if we've already scheduled the picker this session.
        if case .notLoaded = loadState,
           !isPreview,
           !didScheduleResourcePicker {
            didScheduleResourcePicker = true
            // Defer to the next run-loop turn so startAnimation returns
            // before we run a modal panel.
            DispatchQueue.main.async { [weak self] in
                self?.presentResourcePickerIfNeeded()
            }
        }
    }

    public override func stopAnimation() {
        super.stopAnimation()
        // Don't tear down here — viewDidMoveToWindow(nil) is the
        // reliable teardown point on macOS 14+.
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

        // 3. Parse archive + spin up StoryRunner
        do {
            let mapURL       = folder.appendingPathComponent("RESOURCE.MAP")
            let containerURL = folder.appendingPathComponent("RESOURCE.001")
            NSLog("[Johnny] startupIfNeeded: loading archive from %@", folder.path)
            let mapData       = try Data(contentsOf: mapURL)
            let containerData = try Data(contentsOf: containerURL)
            let archive = try ResourceArchive.parse(map: mapData, container: containerData)
            NSLog("[Johnny] startupIfNeeded: archive parsed OK")

            let runner = try StoryRunner(
                archive:      archive,
                dateProvider: SystemDateProvider(),
                sound:        soundSink
            )
            NSLog("[Johnny] startupIfNeeded: StoryRunner created — engine is live")
            self.storyRunner  = runner
            self.loadState    = .loaded
            self.lastTickWall = CACurrentMediaTime()
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
        // Re-check: another code path might have resolved the folder
        // (e.g. configure sheet arrived after all) between the async
        // dispatch and now.
        guard ResourceFolder.resolve() == nil else {
            NSLog("[Johnny] presentResourcePickerIfNeeded: folder already configured — restarting")
            resetAndStartup()
            return
        }

        NSLog("[Johnny] presentResourcePickerIfNeeded: showing setup panel")

        // ---- Informational panel ----------------------------------------

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Johnny Castaway — Setup"
        panel.isReleasedWhenClosed = false
        panel.level = .floating        // appears above the screen-saver view
        panel.center()

        let content = panel.contentView!

        let heading = NSTextField(labelWithString: "Sierra Resource Files Required")
        heading.font = .boldSystemFont(ofSize: 14)
        heading.frame = NSRect(x: 20, y: 136, width: 440, height: 20)
        content.addSubview(heading)

        let body = NSTextField(wrappingLabelWithString:
            "Johnny Castaway needs the original Sierra resource files to run. "
          + "Click \u{201C}Choose Folder\u{2026}\u{201D} and select the folder that contains "
          + "RESOURCE.MAP and RESOURCE.001."
        )
        body.frame = NSRect(x: 20, y: 72, width: 440, height: 56)
        content.addSubview(body)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.frame = NSRect(x: 20, y: 52, width: 440, height: 16)
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
        cancelButton.bezelStyle = .rounded
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
        NSLog("[Johnny] teardown")
        renderer    = nil
        storyRunner = nil
    }

    // ---------------------------------------------------------------
    // MARK: Per-frame
    // ---------------------------------------------------------------

    public override func animateOneFrame() {
        guard let metalLayer = layer as? CAMetalLayer,
              let renderer   = renderer else { return }

        // Pace engine ticks against the previous tick's `mini`.
        if let runner = storyRunner {
            let now       = CACurrentMediaTime()
            let elapsedMS = (now - lastTickWall) * 1000.0
            if elapsedMS >= Double(lastMiniMS) {
                do {
                    if runner.sequenceFinished {
                        try runner.beginNextSequence(rng: &rng)
                    }
                    let mini = try runner.tick(rng: &rng)
                    lastMiniMS   = max(4, mini * 20)
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
