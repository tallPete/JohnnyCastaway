# Johnny Castaway — native macOS screensaver

A faithful native Swift 6 reimplementation of the 1992 Sierra/Dynamix
"Johnny Castaway" screensaver, packaged as a macOS `.saver` bundle.
Renders the original 16-colour pixel art via Metal with nearest-neighbour
integer scaling, driven by the genuine `RESOURCE.MAP` and `RESOURCE.001`
data files.

> **Status: Phase 1 — resource parser complete.** `JohnnyResources`
> parses the canonical RESOURCE.MAP and RESOURCE.001 files, decodes
> both LZW and RLE compression, surfaces typed Palette / Screen /
> Bitmap / TTMScript / ADSScript payloads, and unpacks 4bpp pixel
> data to 8bpp indexed buffers. 62 tests, including an MD5 snapshot
> pin of every decompressed payload across all 180 entries. Engine,
> renderer, and debug packages remain skeleton-only (Phases 2–5).

## Repository layout

```
JohnnyCastaway.xcworkspace/        Open this in Xcode.
Packages/
  JohnnyResources/                 Parser for RESOURCE.MAP / .001
  JohnnyEngine/                    Scheduler, TTM/ADS interpreter,
                                   walk algorithm, holiday triggers.
                                   Outputs a 640×480 indexed framebuffer.
  JohnnyMetalRenderer/             Uploads framebuffer + 16-entry palette
                                   LUT to Metal; integer-scaled blit to
                                   a CAMetalLayer.
  JohnnyDebug/                     SwiftUI overlay (frame stepper, scene
                                   picker, force-date for holiday tests).
Apps/
  JohnnyDebugApp/                  AppKit host for daily-driver dev.
                                   Created in Phase 5.
  JohnnyScreenSaver/               .saver bundle. Created in Phase 6.
Scripts/
  ci.sh                            `swift test` across all four packages.
```

## Bring your own resources

This repo does not ship Sierra/Dynamix IP. To run the engine, you need:

| File         | Size      | MD5                                |
|--------------|-----------|------------------------------------|
| RESOURCE.MAP | 1,461     | `374e6d05c5e0acd88fb5af748948c899` |
| RESOURCE.001 | 1,175,645 | `8bb6c99e9129806b5089a39d24228a36` |
| sound0–24.wav (24 files) | various | (see jc_reborn README) |

These can be extracted from the original 1992 `JOHNNY.EXE` Windows 3.1
program. The [jc_reborn](https://github.com/jno6809/jc_reborn) and
[JCOS](https://github.com/nivs1978/Johnny-Castaway-Open-Source) projects
have instructions. Place them anywhere on disk — the `.saver` will
prompt for their location on first run.

> **Note:** The jc_reborn README has the MD5s for `RESOURCE.MAP` and
> `RESOURCE.001` swapped. The values above are correct (verified against
> the canonical files).

## Building

```bash
# Run all tests across all four SwiftPM packages
./Scripts/ci.sh

# Or per-package
swift test --package-path Packages/JohnnyResources
swift test --package-path Packages/JohnnyEngine
swift test --package-path Packages/JohnnyMetalRenderer
swift test --package-path Packages/JohnnyDebug
```

## Toolchain

- Xcode 16+ (developed on Xcode 26)
- Swift 6 (language mode)
- macOS 14+ deployment target, Apple Silicon primary
- No external Swift package dependencies

## Provenance & credits

This project is a translation, not original archaeology. Engine logic
follows the reverse-engineering work done by:

- **Jérémie Guillaume** ([jno6809/jc_reborn](https://github.com/jno6809/jc_reborn))
  — primary C/SDL2 reference for the resource format, TTM/ADS scripting,
  scheduler, and walking algorithm.
- **Ralph Caraveo** ([deckarep/Johnny-Castaway-2026-Public](https://github.com/deckarep/Johnny-Castaway-2026-Public))
  — Go/Raylib port; source of several documented bug fixes (day/night
  cycle, `IF_IS_RUNNING` skip flag, wave counter modulo) which this Swift
  port adopts.
- **Hans Milling** ([nivs1978/Johnny-Castaway-Open-Source](https://github.com/nivs1978/Johnny-Castaway-Open-Source))
  — earlier C# (JCOS) implementation; original source of much format
  documentation.

The 1992 screensaver itself was developed by Jeff Tunnell Productions /
Dynamix and published by Sierra On-Line under the "Screen Antics" brand.
The IP currently belongs to whatever entity inherited it via the Sierra
→ Vivendi → Activision → Microsoft acquisition chain. This project
distributes only the engine code; resource files must be obtained
separately by the user.

## License

The Swift code in this repository is the author's own work, licensed
under [TBD — to be added in a later phase]. Resource files are not
included and remain subject to their original copyright.
