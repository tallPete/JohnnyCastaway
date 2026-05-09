# Johnny Castaway — native macOS screensaver

A faithful native Swift 6 port of the 1992 Sierra/Dynamix
*Johnny Castaway* screensaver, packaged as a macOS `.saver` bundle.

The original 16-colour pixel art is rendered via Metal with
nearest-neighbour scaling, driven by a clean-room reimplementation of
Sierra's TTM/ADS bytecode interpreter, scene scheduler, walk-graph
pathfinder, and 11-day story arc.

> **No Sierra data is included.** This repository contains only the
> reimplemented engine and renderer. To run the screensaver you must
> supply your own `RESOURCE.MAP`, `RESOURCE.001`, and `sound*.wav`
> files — see [Getting the data files](#getting-the-data-files) below.

---

## Status

**v1.1** — feature-complete and stable. Tested on macOS 26 Tahoe,
Apple Silicon. Runs unattended for hours; the multi-day story arc,
raft progression, holiday decorations, and visitor scenes all play
correctly.

Highlights:

- Full TTM/ADS bytecode interpreter (covers every opcode the canonical
  scripts exercise)
- Scene scheduler with day-of-story advancement, holiday detection,
  night/day cycle
- Walk-graph A* pathfinder
- 11-day story arc persisted across screensaver activations (v1.1)
- Configure sheet with animation speed, force-day, force-holiday,
  fidelity-mode, and debug overlay
- 103 engine unit tests, 11 renderer tests

Known limitations are listed at the bottom of this README.

---

## Installation

### Pre-built (macOS 26 Tahoe, Apple Silicon)

If a release is published, grab the `.saver` zip from the
[Releases](../../releases) page, then:

1. Unzip — you'll get `JohnnyScreenSaver.saver`.
2. Copy it into `~/Library/Screen Savers/`.
3. Strip Gatekeeper's quarantine flag (the build is ad-hoc signed,
   not Apple-Developer-ID signed):

   ```sh
   xattr -dr com.apple.quarantine ~/Library/Screen\ Savers/JohnnyScreenSaver.saver
   ```

   *(Without this step, double-clicking the `.saver` will fail with
   "JohnnyScreenSaver cannot be opened because the developer cannot
   be verified."  An alternative is right-click → Open the first
   time, then accept the warning.)*

4. Open System Settings → Screen Saver → choose JohnnyScreenSaver.
5. Click **Screen Saver Options…**, point it at the folder
   containing your Sierra data files (see below), enable sound if
   you want it, choose a story-day or fidelity mode if you want.

### Build from source

Requires Xcode 16+ (Swift 6 toolchain) on Apple Silicon.

```sh
git clone https://github.com/<user>/JohnnyCastaway.git
cd JohnnyCastaway
bash Apps/JohnnyScreenSaver/Scripts/build-saver.sh --install --reload
```

The script ad-hoc codesigns the bundle, copies it into
`~/Library/Screen Savers/`, and kills the running `legacyScreenSaver`
process so the new build is picked up. You can also build the
engine and tests via SwiftPM:

```sh
cd Packages/JohnnyEngine && swift test          # 103 engine tests
cd Packages/JohnnyMetalRenderer && swift test   # 11 renderer tests
```

---

## Getting the data files

The screensaver requires three sets of files from a legitimate copy
of the original Sierra/Dynamix product:

| File(s)                       | Purpose                          |
|-------------------------------|----------------------------------|
| `RESOURCE.MAP`                | Resource directory (offsets, IDs)|
| `RESOURCE.001`                | Compressed bitmap/script archive |
| `sound0.wav`–`sound24.wav`    | Sound effect samples (optional)  |

These ship with the original 1992 *Johnny Castaway* CD-ROM. If you
have an original copy, copy the files off the disc into a folder of
your choosing, then point the configure sheet at that folder. The
screensaver will not run without `RESOURCE.MAP` and `RESOURCE.001`;
sound files are optional and absent files (notably `sound11.wav` and
`sound13.wav`) are silently skipped.

If you do not have the original media: the same files are required
by every other open-source Johnny Castaway project (jc_reborn,
Johnny-Castaway-2026-Public) — those projects' READMEs note where
the community has historically obtained them. This repository takes
no position and provides no copies.

---

## How it works

```
RESOURCE.MAP / RESOURCE.001
        │
        ▼
JohnnyResources       parser: archive, palette, bitmap, TTM/ADS scripts
        │
        ▼
JohnnyEngine          interpreter: TTM threads, ADS scheduler,
                                   scene scheduler, walk graph,
                                   island/holiday state
        │
        ▼
JohnnyMetalRenderer   R8Uint indexed framebuffer + 16-entry palette LUT
                      shader, fractional-scale letterbox to fill the screen
        │
        ▼
JohnnyScreenSaver     ScreenSaverView host, configure sheet,
(.saver bundle)       resource folder onboarding, AVAudioPlayer sink
```

`JohnnyDebugApp` is a SwiftUI host that drives the same engine for
QA — frame scrubber, thread inspector, scene picker, force-date
controls.

---

## Configure sheet options

| Setting              | Default        | Notes                              |
|----------------------|----------------|------------------------------------|
| Resource folder      | (unset)        | Required; security-scoped bookmark |
| Enable sounds        | Off            | Default off due to Tahoe preview-pane orphan behaviour; toggle on if you want audio |
| Animation speed      | 1.0×           | 0.5× / 1× / 1.5× / 2×              |
| Story day            | Auto           | Override the 11-day arc for testing |
| Force holiday        | Off            | Halloween / St Patrick / Christmas / NY |
| Engine fidelity      | Fixed          | Fixed (Go-port corrections) / Raw (jc_reborn) |
| Show debug overlay   | Off            | Day / threads / opcodes / FPS HUD  |

Force-day and force-holiday are explicitly *temporary* — they don't
overwrite the persistent natural-progression story state.

---

## Acknowledgements

This project would not exist without prior reverse-engineering work
by:

- **Jeremie Guillaume** — `jc_reborn`, the C/SDL port that
  established the canonical TTM/ADS opcode interpretations and
  scene-scheduling logic this engine follows.
- **The author of `Johnny-Castaway-2026-Public`** — a Go port
  whose source-level comments resolved several edge cases in our
  implementation (in particular the `DRAW_SPRITE` indexing
  semantics).

The data files remain Sierra/Dynamix intellectual property; this
project provides no copies and takes no ownership claim over them.

---

## Development

This codebase was developed in collaboration with Anthropic's Claude
(via Claude Code). Co-authorship is recorded in commit trailers
(`Co-Authored-By: Claude …`).

The architecture follows the original plan in
`Native macOS Johnny Castaway Screensaver — Plan.md` — phases 0–6
plus v1.1 polish. Tests are split per-package:

- `Packages/JohnnyEngine/Tests/` — engine logic (103 tests)
- `Packages/JohnnyMetalRenderer/Tests/` — letterbox geometry (11 tests)
- `Packages/JohnnyResources/Tests/` — bitmap/archive parsing

Pull requests welcome, but please note this is a hobby project and
review cadence is best-effort.

---

## Known limitations

- **macOS 26 Tahoe orphan process.** When System Settings'
  screensaver preview is dismissed, the host `legacyScreenSaver`
  process can be left running in the background. This is an Apple
  framework issue (no reliable signal is propagated to the
  `.saver` bundle); manual `killall legacyScreenSaver` cleans it
  up. Defending against this from inside the bundle is documented
  in `JohnnyScreenSaverView.swift` as work that hit a wall.
- **No CRT shader.** The renderer is nearest-neighbour pixel-
  perfect; a Phase 7 polish item would add a CRT/scanline filter.
- **Sound playback.** Default off. Plays at native sample rate
  (matches the original Sierra and jc_reborn).
- **`STAND.ADS` long ambient cycle.** Some idle scenes form a
  self-sustaining `IF_LASTPLAYED` chunk graph that the original
  Sierra cut short via wall-clock pacing pressure we don't
  reproduce. Bounded by an 8000-tick watchdog (~10 minutes worst
  case). See commit `f797d0c` for details.

---

## Licence

[MIT](LICENSE) for the source code in this repository. The Sierra
data files are not covered and are not redistributed.
