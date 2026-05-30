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

// IslandState.swift
//
// Shared state for island rendering: position, tide, raft build progress,
// night mode, and holiday decoration.
// Translated from jc_reborn's struct TIslandState (island.h).

// MARK: - IslandState

/// All per-sequence island configuration.
/// Set by SceneScheduler before each ADS scene and read by IslandRenderer.
public struct IslandState {

    // Night or day (Go fix: hour < 6 || hour >= 18; jc_reborn: (hour%8)∈{0,7})
    public var night: Bool = false

    // Low tide (random, requires LOWTIDE_OK flag on scene)
    public var lowTide: Bool = false

    // Raft build state (0=none, 1–5; derived from story day)
    public var raft: Int = 0

    // Holiday decoration (0=none, 1=Halloween, 2=St Patrick, 3=Christmas, 4=New Year)
    public var holiday: Int = 0

    // Island position offset (pixels); 0,0 = centred; negative = shifted left/up
    public var xPos: Int = 0
    public var yPos: Int = 0

    public init() {}
}

// MARK: - Holiday constants (for tests and external use)

public extension IslandState {
    static let holidayNone:       Int = 0
    static let holidayHalloween:  Int = 1
    static let holidayStPatrick:  Int = 2
    static let holidayChristmas:  Int = 3
    static let holidayNewYear:    Int = 4
}
