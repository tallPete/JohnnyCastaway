# JohnnyScreenSaver

The `.saver` bundle for System Settings → Screen Saver.

## Status

**Not yet created.** Phase 6 of the implementation plan creates this
target as an Xcode project (`.xcodeproj`) inside this directory. The
project will:

- Be a macOS `Bundle` target with `.saver` extension and the
  `NSPrincipalClass` Info.plist key set to `JohnnyScreenSaverView`.
- Depend on the SwiftPM packages above via a workspace reference.
- Subclass `ScreenSaverView`, override `+layerClass` to return
  `CAMetalLayer`, and drive frames from `animateOneFrame()`.
- Implement the configure sheet (`hasConfigureSheet` / `configureSheet`)
  with the preferences listed in the plan (BYO resources, sound, display
  style, animation speed, story day, force holiday, engine fidelity
  mode, debug overlay).
- Handle the Sonoma+ `stopAnimation` lifecycle bug by tearing down
  resources in `viewDidMoveToWindow(nil)` and
  `viewWillMove(toSuperview:)` rather than relying on `stopAnimation`.

## Why no `MTKView`?

Using `MTKView` inside `ScreenSaverView` is a known source of grief in
the macOS developer community. The accepted pattern is to set
`CAMetalLayer` as the view's backing layer via `+layerClass` and drive
drawables manually. The `JohnnyMetalRenderer` package is built around
this assumption.
