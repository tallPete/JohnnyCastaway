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

// DateProvider.swift
//
// Injectable date/time protocol, so holiday and day/night logic can be
// tested deterministically without changing the system clock.
//
// Production code passes SystemDateProvider(); tests pass MockDateProvider
// with a fixed Date.

import Foundation

// MARK: - Protocol

/// Provides the current wall-clock date and time.
public protocol DateProvider: Sendable {
    var currentDate: Date { get }
}

// MARK: - System implementation

/// Production implementation — returns `Date()` (i.e. "now").
public struct SystemDateProvider: DateProvider, @unchecked Sendable {
    public init() {}
    public var currentDate: Date { Date() }
}

// MARK: - Test implementation

/// Test implementation — returns a fixed date supplied at construction.
public struct FixedDateProvider: DateProvider, @unchecked Sendable {
    public let currentDate: Date
    public init(_ date: Date) { self.currentDate = date }

    /// Convenience: construct from year/month/day in the local timezone.
    public init(year: Int, month: Int, day: Int, hour: Int = 12) {
        var comps          = DateComponents()
        comps.year         = year
        comps.month        = month
        comps.day          = day
        comps.hour         = hour
        comps.minute       = 0
        comps.second       = 0
        self.currentDate   = Calendar.current.date(from: comps) ?? Date()
    }
}
