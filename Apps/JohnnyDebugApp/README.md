# JohnnyDebugApp

AppKit / SwiftUI daily-driver development host for JohnnyEngine.
Hosts the same `JohnnyEngine` + `JohnnyMetalRenderer` stack that the
`.saver` will use, plus the `JohnnyDebug` overlay.

## Status

**Phase 5 — complete.** The app is a SwiftPM executable target
(`Package.swift`) rather than an `.xcodeproj`; the bundle metadata
normally supplied by Xcode is embedded directly into the Mach-O binary
via a `__TEXT,__info_plist` section (see `Package.swift` comments).

## Running in Xcode

1. **Open the workspace** — `JohnnyCastaway.xcworkspace` (not this
   `Package.swift`). Xcode resolves all five SwiftPM packages together.

2. **Select the scheme** — In the scheme picker (toolbar, left of the
   run/stop buttons) choose **`JohnnyDebugApp`**. If it doesn't appear,
   choose *Edit Scheme…* or wait a moment for Xcode to finish resolving
   packages, then check again.

3. **Choose a run destination** — set to **My Mac**.

4. **Run** — `Cmd+R`. The app window opens showing the "No Resource
   Files" placeholder screen.

5. **Load resources** — `File > Open Resources…` (or `Cmd+O`).
   Navigate to the folder containing `RESOURCE.MAP` and `RESOURCE.001`.
   Click **Open**. The engine initialises and the animation begins.
   The path is saved in `UserDefaults`; subsequent launches load it
   automatically.

## What you should see

Once resources are loaded:

- The 640×480 island scene renders in the main window, integer-scaled
  to fill the view with black letterboxing.
- The debug overlay appears at the bottom of the window:
  - **Transport row** — Pause/Resume (Space), +1/+10/+100 step buttons,
    Story Loop mode indicator, **Fixed/Raw** fidelity toggle, scene
    picker dropdown, ▶ Play button, Hide/Show Readout toggle.
  - **Thread scrubber** — one capsule per active TTM thread showing slot
    name, tag, current opcode, instruction pointer, and timer. Visible
    only when threads are active.
  - **Readout row** — Day · Scene · Tick · Threads · Opcodes · Sound.
    Hidden when the overlay is collapsed.
  - **Date row** — Force-date toggle + date picker for holiday testing.

## Architecture

```
JohnnyDebugApp.swift        @main SwiftUI App entry point
  AppState                  @Observable; owns resource loading,
                            Engine + StoryRunner; wires frame provider
  ContentView               Switches between ResourceLocatorView
                            (no resources) and DebugView (running)
  DebugView                 ZStack: MetalLayerView + DebugOverlayView
  MetalLayerView            NSViewRepresentable wrapping JohnnyMetalView
```

`AppState` constructs both `Engine` and `StoryRunner` using a shared
`CapturingSoundSink` from `EngineDebugState`, so the last-played sound
sample is visible in the readout overlay.

## Why SwiftPM, not `.xcodeproj`?

The original plan specified an `.xcodeproj`, but the SwiftPM executable
approach works identically for a development tool:

- No code-signing ceremony — Xcode signs ad-hoc for local development.
- `__TEXT,__info_plist` embedding gives the binary a bundle identifier
  (`nz.petesmith.JohnnyDebugApp`), `NSHighResolutionCapable`, and the
  other keys needed for proper GUI-app behaviour without a bundle on disk.
- The `.saver` target (Phase 6) **will** use `.xcodeproj` because `.saver`
  bundles require explicit Xcode packaging and signing config.
- Keeping the debug app in SwiftPM means a single `swift build` command
  (no Xcode required) for headless CI or command-line iteration.
