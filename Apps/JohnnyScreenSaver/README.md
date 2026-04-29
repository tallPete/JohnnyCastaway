# JohnnyScreenSaver

The `.saver` bundle for System Settings → Screen Saver.

## Status — Phase 6 in progress

**Working** (first iteration):
- Builds as a `.saver` bundle (Mach-O `MH_BUNDLE`) via SwiftPM + a
  build script that wraps the dylib with `Info.plist` + `Resources/`.
- Loads in `legacyScreenSaver` via `NSPrincipalClass = JohnnyScreenSaverView`.
- `CAMetalLayer`-backed `ScreenSaverView` with per-instance engine +
  renderer (multi-display safe).
- BYO-resource flow: configure sheet picks a folder via `NSOpenPanel`
  and persists a security-scoped bookmark in
  `ScreenSaverDefaults(forModuleWithName: …)`. Resolved on each saver
  start; access released in teardown.
- Sonoma-aware teardown: explicit cleanup in
  `viewDidMoveToWindow(nil)` and `viewWillMove(toSuperview: nil)` so
  `legacyScreenSaver` drops to ~0% CPU after dismissal.
- Story Loop runs end-to-end (same engine code as JohnnyDebugApp).

**Not yet implemented** (planned):
- Settings sheet controls beyond resource folder: sound, animation
  speed, story day, force holiday, fidelity mode, debug overlay.
- Sound playback (currently `NullSoundSink`; needs `AVAudioPlayer`
  wrapper).
- Bundled `metallib` shipping (currently relies on the renderer
  package finding its shaders at runtime; we copy any default.metallib
  the SwiftPM build emits).

## Build & install

From the workspace root:

```sh
# Build only (output: ./build/JohnnyScreenSaver.saver)
Apps/JohnnyScreenSaver/Scripts/build-saver.sh --debug

# Build + install to ~/Library/Screen Savers/
Apps/JohnnyScreenSaver/Scripts/build-saver.sh --install

# As above, plus kill legacyScreenSaver so System Settings reloads
Apps/JohnnyScreenSaver/Scripts/build-saver.sh --install --reload
```

Then open System Settings → Screen Saver → "Other" section, find
"Johnny Castaway", click "Screen Saver Options…" and pick your
resource folder.

## Architecture

The bundle is produced by SwiftPM as a dynamic library with the
`-bundle` linker flag (so the resulting Mach-O is `MH_BUNDLE`, the
format CFBundle expects to dlopen). `Scripts/build-saver.sh` then:

1. Runs `swift build -c <config>` → `libJohnnyScreenSaver.dylib`
2. Creates `JohnnyScreenSaver.saver/Contents/{MacOS,Resources}/`
3. Copies the dylib to `Contents/MacOS/JohnnyScreenSaver` (renamed
   to match `CFBundleExecutable` in `Info.plist`)
4. Copies `Resources/Info.plist` to `Contents/Info.plist`
5. Copies the renderer's `default.metallib` if present

The principal class `JohnnyScreenSaverView` is exposed to the
Objective-C runtime via `@objc(JohnnyScreenSaverView)` so its name
matches the `NSPrincipalClass` value exactly — `legacyScreenSaver`
looks the class up by string from `Info.plist`.

## Why no `MTKView`?

`MTKView` inside `ScreenSaverView` is known-fragile in the macOS
developer community. The accepted pattern is to set `CAMetalLayer` as
the view's backing layer via `+layerClass` (or `makeBackingLayer()`)
and drive drawables manually from `animateOneFrame()`. The
`JohnnyMetalRenderer` package is built around this assumption.
