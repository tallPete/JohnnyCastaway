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

// SceneCatalogue.swift
//
// Static scene catalogue — all 63 scenes from story_data.h.
// Translated from jc_reborn's story_data.h.
//
// Each StoryScene records:
//   • adsName / adsTag — which ADS resource and tag to play
//   • spotStart/hdgStart — Johnny's position/heading ENTERING the scene
//   • spotEnd/hdgEnd    — Johnny's position/heading LEAVING the scene (0 = doesn't move)
//   • dayNo             — 0 = any day, 1–11 = specific story day
//   • flags             — bitmask of SceneFlags

// MARK: - Spot and heading constants (story_data.h:35–49)

public enum Spot {
    public static let A = 0
    public static let B = 1
    public static let C = 2
    public static let D = 3
    public static let E = 4
    public static let F = 5
}

public enum Heading {
    public static let S  = 0
    public static let SW = 1
    public static let W  = 2
    public static let NW = 3
    public static let N  = 4
    public static let NE = 5
    public static let E  = 6
    public static let SE = 7
}

// MARK: - SceneFlags

public struct SceneFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Scene can be the last one of a day's sequence.
    public static let final_      = SceneFlags(rawValue: 0x01)
    /// Scene can be the first one of a day's sequence (no walk-in).
    public static let first       = SceneFlags(rawValue: 0x02)
    /// Requires island background (BACKGRND.BMP + ocean).
    public static let island      = SceneFlags(rawValue: 0x04)
    /// Camera placed left (LEFT_ISLAND: xPos offset = -272).
    public static let leftIsland  = SceneFlags(rawValue: 0x08)
    /// Island position may be randomised (VARPOS_OK).
    public static let varPosOK    = SceneFlags(rawValue: 0x10)
    /// Low-tide variant is allowed (LOWTIDE_OK).
    public static let lowTideOK   = SceneFlags(rawValue: 0x20)
    /// Raft sprite not shown in this scene (NORAFT).
    public static let noRaft      = SceneFlags(rawValue: 0x40)
    /// Holiday decoration suppressed (HOLIDAY_NOK).
    public static let holidayNOK  = SceneFlags(rawValue: 0x80)
}

// MARK: - StoryScene

/// One entry in the scene catalogue (story_data.h:51–60).
public struct StoryScene: Sendable {
    public let adsName:   String
    public let adsTag:    Int
    public let spotStart: Int   // 0 when undefined
    public let hdgStart:  Int   // 0 when undefined
    public let spotEnd:   Int   // 0 means "doesn't move"
    public let hdgEnd:    Int   // 0 means "doesn't move"
    public let dayNo:     Int   // 0 = any day
    public let flags:     SceneFlags
}

// MARK: - Catalogue (story_data.h:63–141)
// 63 scenes; order matches the C array exactly.

public let storyScenes: [StoryScene] = [

    //              Name          Tag   Start                  End             Day  Flags
    StoryScene("ACTIVITY.ADS",  1, Spot.E, Heading.SE,        0,          0,   0,  [.island, .final_, .varPosOK]),
    StoryScene("ACTIVITY.ADS", 12, Spot.D, Heading.SW,        0,          0,   0,  [.island, .final_, .varPosOK, .lowTideOK]),
    StoryScene("ACTIVITY.ADS", 11,      0,          0,        0,          0,   0,  [.island, .final_, .first, .varPosOK]),
    StoryScene("ACTIVITY.ADS", 10, Spot.D, Heading.SW,        0,          0,   0,  [.island, .final_, .varPosOK, .lowTideOK]),
    StoryScene("ACTIVITY.ADS",  4, Spot.E, Heading.SE, Spot.E, Heading.SE,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("ACTIVITY.ADS",  5, Spot.E, Heading.SW,        0,          0,   0,  [.island, .final_, .varPosOK, .lowTideOK]),
    StoryScene("ACTIVITY.ADS",  6, Spot.D, Heading.SW,        0,          0,   0,  [.island, .final_, .varPosOK]),
    StoryScene("ACTIVITY.ADS",  7, Spot.D, Heading.SW, Spot.F, Heading.SW,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("ACTIVITY.ADS",  8,      0,          0, Spot.D, Heading.SE,   0,  [.island, .first, .varPosOK]),
    StoryScene("ACTIVITY.ADS",  9, Spot.E, Heading.E,         0,          0,   0,  [.island, .final_, .lowTideOK]),

    StoryScene("BUILDING.ADS",  1, Spot.F, Heading.W,  Spot.A, Heading.W,    0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("BUILDING.ADS",  4, Spot.A, Heading.E,         0,          0,   0,  [.island, .final_, .varPosOK]),
    StoryScene("BUILDING.ADS",  3, Spot.A, Heading.E,  Spot.C, Heading.SE,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("BUILDING.ADS",  2, Spot.F, Heading.W,         0,          0,   0,  [.island, .final_, .varPosOK]),
    StoryScene("BUILDING.ADS",  5, Spot.D, Heading.W,  Spot.D, Heading.E,    0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("BUILDING.ADS",  7, Spot.D, Heading.W,  Spot.D, Heading.E,    0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("BUILDING.ADS",  6, Spot.A, Heading.E,         0,          0,   0,  [.island, .final_, .varPosOK]),

    StoryScene("FISHING.ADS",   1, Spot.D, Heading.W,  Spot.D, Heading.E,    0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("FISHING.ADS",   2, Spot.D, Heading.W,  Spot.D, Heading.E,    0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("FISHING.ADS",   3, Spot.D, Heading.W,         0,          0,   0,  [.island, .final_, .varPosOK, .lowTideOK]),
    StoryScene("FISHING.ADS",   4, Spot.E, Heading.E,         0,          0,   0,  [.island, .final_, .leftIsland, .lowTideOK]),
    StoryScene("FISHING.ADS",   5, Spot.E, Heading.E,         0,          0,   0,  [.island, .final_, .varPosOK]),
    StoryScene("FISHING.ADS",   6, Spot.D, Heading.W,         0,          0,   0,  [.island, .final_, .lowTideOK]),
    StoryScene("FISHING.ADS",   7, Spot.E, Heading.E,  Spot.E, Heading.W,    0,  [.island, .leftIsland, .varPosOK, .lowTideOK]),
    StoryScene("FISHING.ADS",   8, Spot.E, Heading.E,  Spot.E, Heading.W,    0,  [.island, .leftIsland, .varPosOK, .lowTideOK]),

    StoryScene("JOHNNY.ADS",    1,      0,          0,        0,          0,  11,  [.final_, .first]),
    StoryScene("JOHNNY.ADS",    2, Spot.E, Heading.SW, Spot.F,          0,   2,  [.island, .final_, .varPosOK]),
    StoryScene("JOHNNY.ADS",    3, Spot.E, Heading.SW, Spot.F, Heading.NE,   6,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("JOHNNY.ADS",    4, Spot.E, Heading.SW, Spot.F, Heading.NE,   0,  [.island, .varPosOK]),
    StoryScene("JOHNNY.ADS",    5, Spot.E, Heading.SW, Spot.F, Heading.NE,   0,  [.island, .varPosOK]),
    StoryScene("JOHNNY.ADS",    6,      0,          0,        0,          0,  10,  [.final_, .first]),

    StoryScene("MARY.ADS",      1, Spot.E, Heading.SW,        0,          0,   5,  [.island, .final_, .varPosOK, .lowTideOK]),
    StoryScene("MARY.ADS",      3, Spot.F, Heading.SW,        0,          0,   4,  [.island, .final_, .first, .varPosOK]),
    StoryScene("MARY.ADS",      2, Spot.E, Heading.E,         0,          0,   1,  [.island, .final_, .varPosOK]),
    StoryScene("MARY.ADS",      4, Spot.E, Heading.E,         0,          0,   7,  [.island, .final_, .varPosOK]),
    StoryScene("MARY.ADS",      5, Spot.E, Heading.NW,        0,          0,   8,  [.island, .leftIsland, .final_, .first, .noRaft, .varPosOK]),

    StoryScene("MISCGAG.ADS",   1, Spot.D, Heading.W,         0,          0,   0,  [.island, .final_, .varPosOK, .lowTideOK]),
    StoryScene("MISCGAG.ADS",   2, Spot.D, Heading.W,         0,          0,   0,  [.island, .final_, .varPosOK]),

    StoryScene("STAND.ADS",     1, Spot.A, Heading.SW, Spot.A, Heading.SW,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",     2, Spot.A, Heading.W,  Spot.A, Heading.W,    0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",     3, Spot.A, Heading.NW, Spot.A, Heading.NW,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",     4, Spot.B, Heading.SW, Spot.B, Heading.SW,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",     5, Spot.B, Heading.S,  Spot.B, Heading.S,    0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",     6, Spot.B, Heading.SE, Spot.B, Heading.SE,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",     7, Spot.C, Heading.NE, Spot.C, Heading.NE,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",     8, Spot.C, Heading.E,  Spot.C, Heading.E,    0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",     9, Spot.D, Heading.NW, Spot.D, Heading.NW,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",    10, Spot.D, Heading.NE, Spot.D, Heading.NE,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",    11, Spot.E, Heading.NW, Spot.E, Heading.NW,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",    12, Spot.F, Heading.S,  Spot.F, Heading.S,    0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",    15, Spot.A, Heading.S,  Spot.A, Heading.S,    0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("STAND.ADS",    16, Spot.C, Heading.S,  Spot.C, Heading.S,    0,  [.island, .varPosOK, .lowTideOK]),

    StoryScene("SUZY.ADS",      1,      0,          0,        0,          0,   3,  [.final_, .first]),
    StoryScene("SUZY.ADS",      2,      0,          0,        0,          0,   9,  [.final_, .first]),

    StoryScene("VISITOR.ADS",   1, Spot.A, Heading.S,  Spot.A, Heading.S,    0,  [.island, .lowTideOK]),
    StoryScene("VISITOR.ADS",   3, Spot.B, Heading.NW, Spot.D,          0,   0,  [.island, .final_, .holidayNOK]),
    StoryScene("VISITOR.ADS",   4, Spot.D, Heading.S,  Spot.D, Heading.W,    0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("VISITOR.ADS",   6, Spot.D, Heading.S,  Spot.D, Heading.SW,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("VISITOR.ADS",   7, Spot.D, Heading.S,  Spot.D, Heading.SW,   0,  [.island, .varPosOK, .lowTideOK]),
    StoryScene("VISITOR.ADS",   5, Spot.E, Heading.SW,        0,          0,   0,  [.island, .final_, .leftIsland, .varPosOK, .lowTideOK]),

    StoryScene("WALKSTUF.ADS",  1, Spot.A, Heading.NE,        0,          0,   0,  [.island, .final_, .lowTideOK]),
    StoryScene("WALKSTUF.ADS",  2, Spot.E, Heading.E,  Spot.D, Heading.SE,   0,  [.island, .varPosOK]),
    StoryScene("WALKSTUF.ADS",  3, Spot.D, Heading.W,  Spot.E, Heading.W,    0,  [.island, .varPosOK, .lowTideOK]),
]

// MARK: - Convenience init

private extension StoryScene {
    init(_ name: String, _ tag: Int,
         _ spotStart: Int, _ hdgStart: Int,
         _ spotEnd: Int,   _ hdgEnd: Int,
         _ dayNo: Int,
         _ flags: SceneFlags) {
        self.adsName   = name
        self.adsTag    = tag
        self.spotStart = spotStart
        self.hdgStart  = hdgStart
        self.spotEnd   = spotEnd
        self.hdgEnd    = hdgEnd
        self.dayNo     = dayNo
        self.flags     = flags
    }
}
