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
// sheet; we store a security-scoped bookmark in
// ScreenSaverDefaults(forModuleWithName: BUNDLE_ID). On next launch
// we resolve the bookmark and start access. If no bookmark is set
// (first run), we render the "needs resources" idle frame instead of
// failing.

import ScreenSaver
import AppKit
import Metal
import QuartzCore
import JohnnyResources
import JohnnyEngine
import JohnnyMetalRenderer

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

    /// Held while we're using the user's chosen resource folder.
    /// Released in teardown so the system can revoke access cleanly.
    private var resourceFolderURL: URL?

    // ---------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        // ScreenSaverView's animationTimeInterval is the cadence at
        // which animateOneFrame() is called. We pace internally
        // anyway, so a high cadence (1/30 s) is fine.
        animationTimeInterval = 1.0 / 30.0
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        animationTimeInterval = 1.0 / 30.0
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
        guard renderer == nil else { return }   // already running

        // 1. Metal device + renderer
        guard let device = MTLCreateSystemDefaultDevice() else {
            loadState = .error("No Metal device")
            return
        }
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.device       = device
            metalLayer.drawableSize = convertToBacking(bounds.size)
        }
        do {
            renderer = try EngineRenderer(device: device)
        } catch {
            loadState = .error("Renderer: \(error.localizedDescription)")
            return
        }

        // 2. Resolve user's resource folder via security-scoped bookmark
        guard let folder = ResourceFolder.resolve() else {
            loadState = .notLoaded
            return
        }
        resourceFolderURL = folder

        // 3. Parse archive + spin up StoryRunner
        do {
            let mapURL       = folder.appendingPathComponent("RESOURCE.MAP")
            let containerURL = folder.appendingPathComponent("RESOURCE.001")
            let mapData       = try Data(contentsOf: mapURL)
            let containerData = try Data(contentsOf: containerURL)
            let archive = try ResourceArchive.parse(map: mapData, container: containerData)

            let runner = try StoryRunner(
                archive:      archive,
                dateProvider: SystemDateProvider(),
                sound:        soundSink
            )
            self.storyRunner = runner
            self.loadState   = .loaded
            self.lastTickWall = CACurrentMediaTime()
        } catch {
            loadState = .error("Resources: \(error.localizedDescription)")
        }
    }

    // ---------------------------------------------------------------
    // MARK: Teardown (Sonoma-reliable)
    // ---------------------------------------------------------------

    private func teardown() {
        renderer    = nil
        storyRunner = nil
        if let url = resourceFolderURL {
            url.stopAccessingSecurityScopedResource()
            resourceFolderURL = nil
        }
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

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        return ConfigureSheetController.shared.window
    }
}
