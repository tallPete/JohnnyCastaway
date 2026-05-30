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

// MainThreadStallMonitor.swift
//
// A background-thread watchdog that detects when the screensaver's MAIN
// thread has stopped making progress ("the spin / freeze"), and records a
// diagnostic dump pinpointing where it wedged.
//
// WHY THIS EXISTS
// ---------------
// After several hours the screensaver can wedge: the picture freezes and one
// CPU core pegs.  Crucially, every existing self-recovery path in
// JohnnyScreenSaverView runs ON the main thread:
//
//   • the orphan getppid() check lives inside animateOneFrame()
//   • the "emergency exit" watchdog is a DispatchQueue.main.asyncAfter
//
// So the one failure mode they're meant to handle — a wedged main thread —
// is exactly the case where NONE of them can ever fire.  The leaked
// legacyScreenSaver host then lives forever, and the *next* activation
// reuses/contends with that stuck process, producing the reported
// "black screen on restart".
//
// This monitor runs on its own background Thread, immune to the main-thread
// wedge.  It is DIAGNOSTIC ONLY — it never calls exit() and never changes
// engine behaviour.  When it sees the main thread go quiet it logs:
//   1. the last "breadcrumb" the main thread recorded (which operation it was
//      about to run — engine tick / nextDrawable / render), and
//   2. the last engine state snapshot (day / scene / state-machine / threads).
//
// That tells us, the next time it happens, EXACTLY where the spin lives —
// without having to attach a debugger to a multi-hour repro.
//
// Output goes to the unified log (NSLog, visible in Console.app or
//   `log show --predicate 'process == "legacyScreenSaver"' --last 6h`)
// and is appended to "JohnnyCastaway-stall.log" inside the user's resource
// folder, which the saver already holds sandbox write access to.

import Foundation
import QuartzCore

/// Background-thread liveness monitor for the screensaver's main thread.
///
/// Thread-safety: all shared state is guarded by `lock`.  The main thread
/// calls `beat(_:snapshot:)` once per frame (cheap); a dedicated background
/// thread polls `check()` every few seconds.  Critical sections are kept
/// tiny so the poller can never be blocked by a main thread that wedges
/// *inside* a `beat` call (the wedge is always in the engine/render code the
/// breadcrumb points at, never inside `beat` itself).
final class MainThreadStallMonitor: @unchecked Sendable {

    // ---- Tunables ----------------------------------------------------

    /// How long the main thread may go without a heartbeat before we treat
    /// it as wedged.  At the view's 100 Hz timer this is ~1500 missed
    /// frames — far beyond any legitimate per-frame cost (the per-scene
    /// 8000-tick watchdog still ticks waves every frame; nextDrawable blocks
    /// at most one vsync interval), so false positives are not realistic.
    private let stallThreshold: CFTimeInterval = 15.0

    /// How often the background thread checks for a stall.
    private let checkInterval: TimeInterval = 3.0

    /// Once stalled, how often to re-log that we're STILL stalled (so the log
    /// shows the wedge never recovered, without spamming a line every check).
    private let restallReportInterval: CFTimeInterval = 30.0

    // ---- Guarded state ----------------------------------------------

    private let lock = NSLock()
    private var lastBeat: CFTimeInterval = CACurrentMediaTime()
    private var lastCrumb: String = "init"
    private var lastSnapshot: String = "(no engine snapshot yet)"
    private var active: Bool = false
    private var logFileURL: URL?
    private var stalled: Bool = false
    private var lastReportTime: CFTimeInterval = 0

    private var thread: Thread?

    /// Short hex id so multi-display setups (one instance per screen, all in
    /// the same pid) can be told apart in the shared log file.  An immutable
    /// `let` set in init — safe to read from both the main and poller threads.
    private let instanceTag: String

    /// Timestamp formatter for the file sink.  Only ever touched by the single
    /// poller thread (via `writeLine` ← `check`), so per-instance ownership
    /// avoids any cross-thread sharing of the non-Sendable DateFormatter.
    private let timestampFormatter: DateFormatter

    init() {
        instanceTag = String(format: "%06x", UInt32.random(in: 0 ... 0xFFFFFF))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        timestampFormatter = f
    }

    // ---- Lifecycle ---------------------------------------------------

    /// Point the file sink at the user's resource folder (sandbox-writable).
    /// Safe to call before or after `start()`; nil keeps logging to NSLog only.
    func configure(logFileURL: URL?) {
        lock.lock()
        self.logFileURL = logFileURL
        lock.unlock()
        if let url = logFileURL {
            NSLog("[Johnny][stall] monitor logging to %@", url.path)
        }
    }

    /// Start the background polling thread.  Idempotent.
    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "nz.petesmith.JohnnyStallMonitor"
        t.stackSize = 256 * 1024
        thread = t
        t.start()
        NSLog("[Johnny][stall] monitor thread started (threshold=%.0fs)", stallThreshold)
    }

    /// Enable/disable stall detection.  The view calls `setActive(true)` only
    /// while genuinely full-screen in legacyScreenSaver, and `setActive(false)`
    /// on every stop/teardown — so a *legitimate* stop (which runs on the main
    /// thread, proving it's alive) is never misread as a wedge, and the
    /// System Settings preview pane is never monitored.
    func setActive(_ isActive: Bool) {
        lock.lock()
        active = isActive
        if isActive {
            // Treat (re)activation as a fresh heartbeat so a long idle period
            // while inactive doesn't trip the detector the instant we resume.
            lastBeat = CACurrentMediaTime()
            stalled = false
        }
        lock.unlock()
    }

    // ---- Main-thread heartbeat --------------------------------------

    /// Record that the main thread reached a checkpoint.  Call once per frame
    /// with a short, allocation-free `crumb` describing the operation about to
    /// run; pass `snapshot` (richer engine state) only when cheap to build
    /// (i.e. at the paced engine-tick rate, not every 100 Hz frame).
    func beat(_ crumb: String, snapshot: String? = nil) {
        let now = CACurrentMediaTime()
        lock.lock()
        lastBeat = now
        lastCrumb = crumb
        if let snapshot { lastSnapshot = snapshot }
        let recovered = stalled
        stalled = false
        lock.unlock()
        if recovered {
            // The main thread came back to life after we'd reported a stall.
            // Worth knowing (it means the freeze was transient, not a true
            // permanent wedge).  NSLog is safe from the main thread here.
            NSLog("[Johnny][stall][%@] main thread RECOVERED — now at: %@",
                  instanceTag, crumb)
        }
    }

    // ---- Background poller ------------------------------------------

    private func runLoop() {
        while !Thread.current.isCancelled {
            Thread.sleep(forTimeInterval: checkInterval)
            check()
        }
    }

    private func check() {
        let now = CACurrentMediaTime()
        lock.lock()
        let isActive   = active
        let beat       = lastBeat
        let crumb      = lastCrumb
        let snapshot   = lastSnapshot
        let url        = logFileURL
        let wasStalled = stalled
        let sinceReport = now - lastReportTime
        guard isActive, now - beat >= stallThreshold else {
            lock.unlock()
            return
        }
        // We are stalled.  Decide whether to log this round.
        let firstReport = !wasStalled
        let shouldLog: Bool
        if firstReport {
            stalled = true
            lastReportTime = now
            shouldLog = true
        } else if sinceReport >= restallReportInterval {
            lastReportTime = now
            shouldLog = true
        } else {
            shouldLog = false
        }
        lock.unlock()

        guard shouldLog else { return }

        let idle = now - beat
        let proc = ProcessInfo.processInfo
        if firstReport {
            let header = String(
                format: "MAIN THREAD STALLED — idle %.1fs (threshold %.0fs). " +
                        "Wedged at: %@",
                idle, stallThreshold, crumb)
            let detail = String(
                format: "last engine snapshot: %@ | proc=%@ pid=%d ppid=%d",
                snapshot, proc.processName, proc.processIdentifier, getppid())
            NSLog("[Johnny][stall][%@] %@", instanceTag, header)
            NSLog("[Johnny][stall][%@] %@", instanceTag, detail)
            writeLine("STALL  \(header)", url: url)
            writeLine("STALL  \(detail)", url: url)
        } else {
            let line = String(format: "STILL STALLED — idle %.1fs, wedged at: %@",
                              idle, crumb)
            NSLog("[Johnny][stall][%@] %@", instanceTag, line)
            writeLine(line, url: url)
        }
    }

    // ---- File sink ---------------------------------------------------

    private func writeLine(_ message: String, url: URL?) {
        guard let url else { return }
        let stamp = timestampFormatter.string(from: Date())
        let line = "\(stamp) [\(instanceTag)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // File doesn't exist yet (or couldn't be opened for append) —
            // create it.  Failure here is non-fatal; NSLog still captured it.
            try? data.write(to: url, options: .atomic)
        }
    }
}
