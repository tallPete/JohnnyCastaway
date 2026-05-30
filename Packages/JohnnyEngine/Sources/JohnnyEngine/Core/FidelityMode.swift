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
// any later version. See the COPYING file or <https://www.gnu.org/licenses/>.

// FidelityMode.swift
//
// Selects between the Go-port corrected engine behaviour (.fixed) and
// the jc_reborn-canonical behaviour (.raw). Controlled by the debug
// overlay; defaults to .fixed in all production paths.
//
// Differences (plan §1.13):
//   Day/night:     .fixed  hour < 6 || hour >= 18
//                  .raw    (hour % 8) ∈ {0, 7}  — visibly broken
//   IF_IS_RUNNING: .fixed  inSkipBlock = !isSceneRunning  — Go correction
//                  .raw    inSkipBlock =  isSceneRunning  — jc_reborn bug
//   Wave modulo:   .fixed  counter1 %= 2  — 2-frame cycle
//                  .raw    counter1 %= 3  — jc_reborn value

public enum FidelityMode: String, CaseIterable, Equatable, Sendable {
    case fixed  // Go-port corrections applied (recommended)
    case raw    // jc_reborn-canonical (for A/B verification)
}
