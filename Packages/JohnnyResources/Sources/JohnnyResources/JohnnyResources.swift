// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Peter Smith
//
// This file is part of the Johnny Castaway macOS screensaver, a derivative
// work of 'Johnny Reborn' (jc_reborn) by Jeremie Guillaume.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file or <https://www.gnu.org/licenses/>.

// JohnnyResources
//
// Parser for Sierra/Dynamix RESOURCE.MAP and RESOURCE.001 container
// files used by the 1992 "Johnny Castaway" screensaver.
//
// Public surface (Phase 1):
//
//   * `ResourceArchive.parse(map:container:)` — the top-level entry
//     point. Returns a typed catalogue of every entry in the container.
//   * `ResourceMap` — parsed RESOURCE.MAP (length/offset records).
//   * `Resource` — sum type over the parsed payloads:
//     `.palette`, `.screen`, `.bitmap`, `.ttmScript`, `.adsScript`,
//     `.unrecognised`.
//   * `Palette`, `Screen`, `Bitmap`, `TTMScript`, `ADSScript` — typed
//     payloads.
//   * `Indexed8.rasterize(...)` — turn an indexed pixel buffer plus
//     a `Palette` into RGBA8 bytes for diagnostic / renderer use.
//   * `ParserError` — thrown on any malformed input; carries the byte
//     offset and a human-readable breadcrumb.
//
// All multi-byte fields in the on-disk format are little-endian.
// Translation source files are noted in each parser file's header.

import Foundation

public enum JohnnyResources {
    /// Semantic version of the parser module. Bumped at major
    /// milestones; per-phase work does not bump this.
    public static let version = "0.0.0-phase0"
}
