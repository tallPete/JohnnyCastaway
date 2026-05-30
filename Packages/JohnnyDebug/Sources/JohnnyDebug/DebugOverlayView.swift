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

// DebugOverlayView.swift
//
// SwiftUI debug overlay for JohnnyDebugApp (and optionally the .saver).
//
// Layout (bottom of screen, bottom-to-top z-order):
//   Row 1 — Transport: Pause/Resume · +1 · +10 · +100 · [Story Loop] ·
//            [Fixed/Raw fidelity toggle] · [scene picker] · [▶ Play] ·
//            [👁 Show/Hide readout]
//   Row 2 — Thread scrubber: one pill per active TTM thread (slot:tag
//            opcode@ip timer). Hidden when isOverlayVisible == false.
//   Row 3 — Readout: Day · Scene · Tick · Threads · Opcodes · Sound.
//            Hidden when isOverlayVisible == false.
//   Row 4 — Force date: toggle · DatePicker. Always visible.

import SwiftUI
import JohnnyEngine

// MARK: - DebugOverlayView

@MainActor
public struct DebugOverlayView: View {

    @Bindable var state: EngineDebugState

    public init(state: EngineDebugState) {
        self.state = state
    }

    // MARK: - Scene picker data

    private var scenePicks: [(id: String, label: String)] {
        var seen   = Set<String>()
        var result = [(id: String, label: String)]()
        for scene in storyScenes {
            let id = "\(scene.adsName):\(scene.adsTag)"
            guard seen.insert(id).inserted else { continue }
            let flags = flagsAbbrev(scene.flags)
            let label = flags.isEmpty ? id : "\(id)  \(flags)"
            result.append((id: id, label: label))
        }
        return result.sorted { $0.id < $1.id }
    }

    private var selectedSceneID: String {
        "\(state.selectedADSName):\(state.selectedADSTag)"
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            transportRow
            if state.isOverlayVisible {
                if !state.threadSnapshots.isEmpty {
                    scrubberRow
                }
                readoutRow
            }
            dateRow
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Transport row

    private var transportRow: some View {
        HStack(spacing: 6) {
            // Pause / Resume
            Button(state.isPaused ? "▶ Resume" : "⏸ Pause") {
                state.isPaused.toggle()
                if !state.isPaused { state.step(0) }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(" ", modifiers: [])
            .help("Space — toggle pause")

            Divider().frame(height: 18)

            // Step buttons
            Group {
                Button("+1")  { state.step(1)   }.help("Advance 1 tick")
                Button("+10") { state.step(10)  }.help("Advance 10 ticks")
                Button("+100"){ state.step(100) }.help("Advance 100 ticks")
            }
            .buttonStyle(.bordered)

            Divider().frame(height: 18)

            // Story-loop toggle
            if state.mode == .storyLoop {
                Button("Story Loop") { state.switchToStoryLoop() }
                    .buttonStyle(.borderedProminent)
                    .help("Currently in story-loop mode")
            } else {
                Button("Story Loop") { state.switchToStoryLoop() }
                    .buttonStyle(.bordered)
                    .help("Switch to full story-loop mode")
            }

            Divider().frame(height: 18)

            // Fidelity-mode toggle
            fidelityToggle

            Divider().frame(height: 18)

            // Scene picker
            Picker("", selection: Binding(
                get: { selectedSceneID },
                set: { newID in
                    let parts = newID.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, let tag = Int(parts[1]) {
                        state.selectedADSName = String(parts[0])
                        state.selectedADSTag  = tag
                    }
                }
            )) {
                ForEach(scenePicks, id: \.id) { pick in
                    Text(pick.label).tag(pick.id)
                }
            }
            .frame(minWidth: 220, maxWidth: 320)
            .labelsHidden()
            .help("Pick a scene for override mode")

            Button("▶ Play") {
                try? state.playSelectedScene()
            }
            .buttonStyle(.borderedProminent)
            .help("Play selected scene in override mode")

            Spacer(minLength: 0)

            // Overlay visibility toggle (right-justified)
            Button(state.isOverlayVisible ? "Hide Readout" : "Show Readout") {
                state.isOverlayVisible.toggle()
            }
            .buttonStyle(.bordered)
            .help("Toggle visibility of readout and thread scrubber")
            .keyboardShortcut("d", modifiers: [.command])
        }
    }

    // MARK: - Fidelity toggle

    private var fidelityToggle: some View {
        HStack(spacing: 0) {
            fidelityButton(.fixed, label: "Fixed",
                           help: "Fixed: apply Go-port corrections (recommended)")
            fidelityButton(.raw,   label: "Raw",
                           help: "Raw: jc_reborn-canonical for A/B verification")
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func fidelityButton(_ mode: FidelityMode,
                                label: String,
                                help: String) -> some View {
        if state.fidelityMode == mode {
            Button(label) { state.fidelityMode = mode }
                .buttonStyle(.borderedProminent)
                .help(help)
        } else {
            Button(label) { state.fidelityMode = mode }
                .buttonStyle(.bordered)
                .help(help)
        }
    }

    // MARK: - Thread scrubber row

    private var scrubberRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(state.threadSnapshots.enumerated()), id: \.offset) { _, snap in
                    threadPill(snap)
                }
            }
        }
    }

    private func threadPill(_ snap: TTMThreadSnapshot) -> some View {
        let name      = snap.slotName.replacingOccurrences(of: ".TTM", with: "")
        let opcodeStr: String
        if let op = snap.currentOpcode {
            opcodeStr = String(format: "0x%04X", op)
        } else {
            opcodeStr = "EOF"
        }
        let ipStr    = String(format: "0x%X", snap.ip)
        let timerStr = "T:\(snap.timer)/\(snap.delay)"
        let label    = "\(name):\(snap.tag)"
        return threadPillView(label: label, opcode: opcodeStr, ip: ipStr, timer: timerStr)
    }

    private func threadPillView(label: String, opcode: String,
                                ip: String, timer: String) -> some View {
        HStack(spacing: 4) {
            Text(label).fontWeight(.semibold)
            Text(opcode)
            Text("@\(ip)").foregroundStyle(.secondary)
            Text(timer).foregroundStyle(.tertiary)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }

    // MARK: - Date row

    private var dateRow: some View {
        HStack(spacing: 8) {
            Toggle("Force date:", isOn: $state.useForceDate)
            if state.useForceDate {
                DatePicker("", selection: $state.forcedDate,
                           displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .frame(maxWidth: 140)
                Text("(restart sequence to apply)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Readout row

    private var readoutRow: some View {
        HStack(spacing: 10) {
            readout("Day",     value: "\(state.storyDay)")
            dot
            readout("Scene",   value: state.sequenceLabel)
            dot
            readout("Tick",    value: "\(state.currentTick)")
            dot
            readout("Threads", value: "\(state.activeThreadCount)")
            dot
            readout("Opcodes", value: "\(state.coveredOpcodeCount)")
            dot
            soundReadout
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private var soundReadout: some View {
        HStack(spacing: 2) {
            Text("Sound:").foregroundStyle(.tertiary)
            if let id = state.lastSoundTrigger {
                Text("sound\(id)")
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    private var dot: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private func readout(_ label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text("\(label):").foregroundStyle(.tertiary)
            Text(value)
        }
    }

    // MARK: - Helpers

    private func flagsAbbrev(_ flags: SceneFlags) -> String {
        var parts = [String]()
        if flags.contains(.final_)     { parts.append("FIN") }
        if flags.contains(.first)      { parts.append("FST") }
        if flags.contains(.island)     { parts.append("ISL") }
        if flags.contains(.holidayNOK) { parts.append("NOH") }
        if flags.contains(.noRaft)     { parts.append("NOR") }
        return parts.isEmpty ? "" : "[\(parts.joined(separator: ","))]"
    }
}
