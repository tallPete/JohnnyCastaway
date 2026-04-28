# JohnnyDebugApp

AppKit host application for daily-driver development. Hosts the same
`JohnnyEngine` + `JohnnyMetalRenderer` stack that the `.saver` uses,
plus the `JohnnyDebug` SwiftUI overlay (frame stepper, scene picker,
force-date for holiday tests, fidelity-mode toggle).

## Status

**Not yet created.** Phase 5 of the implementation plan creates this
target as an Xcode project (`.xcodeproj`) inside this directory. The
project will:

- Be a `macOS App` target (`NSApplication`, no SwiftUI lifecycle so we
  control window setup directly).
- Depend on the SwiftPM packages above via a workspace reference.
- Embed a single `NSWindow` hosting an `NSView` with a `CAMetalLayer`
  backing layer; the SwiftUI debug overlay sits on top via
  `NSHostingView`.
- Read the user's `RESOURCE.MAP` / `RESOURCE.001` from a hardcoded
  developer path (or via a `Locate resources…` menu) — no
  `.saver`-style onboarding here.

## Why a separate Xcode project, not a SwiftPM executable?

The `JohnnyScreenSaver.saver` target needs Xcode for:
- The `loginitem`-style `Bundle` packaging (`.saver` is a bundle,
  not an app).
- Code signing config that survives `legacyScreenSaver` hosting.

The debug app gets the same Xcode treatment so the build settings,
signing, and hardened-runtime decisions are made *once* and used by
both targets.
