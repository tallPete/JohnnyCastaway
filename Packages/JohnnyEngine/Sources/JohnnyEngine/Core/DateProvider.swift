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
