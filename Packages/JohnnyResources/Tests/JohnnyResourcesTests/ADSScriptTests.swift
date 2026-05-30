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

// ADSScriptTests.swift

import Testing
import Foundation
@testable import JohnnyResources

@Suite("ADSScript parsing (canonical)",
       .disabled(if: !TestResources.available, TestResources.skipMessage))
struct ADSScriptTests {

    @Test("Every ADS has 5-byte version, non-empty bytecode, and self-consistent tag tables")
    func structure() throws {
        let archive = try ContainerTests.archive()
        let adss = archive.entries(of: .adsScript)
        #expect(!adss.isEmpty, "no ADS entries found")

        for entry in adss {
            guard case .adsScript(let s) = entry.resource else { continue }
            #expect(s.version.count == 5, "\(entry.name) version length")
            #expect(s.versionSize == 5)
            #expect(s.bytecode.count > 0, "\(entry.name) empty bytecode")
            #expect(s.adsUnknown.count == 4)
            for ref in s.referencedResources {
                #expect(ref.name.count <= 39, "\(entry.name) ref name too long")
            }
            for tag in s.tags {
                #expect(tag.description.count <= 39, "\(entry.name) tag desc too long")
            }
        }
    }

    @Test("Referenced resources point at parseable .TTM entries in the same archive")
    func referencedTTMsExist() throws {
        let archive = try ContainerTests.archive()
        for entry in archive.entries(of: .adsScript) {
            guard case .adsScript(let s) = entry.resource else { continue }
            for ref in s.referencedResources {
                let target = archive.entry(named: ref.name)
                #expect(
                    target != nil,
                    "\(entry.name) references missing resource '\(ref.name)'"
                )
                if let target {
                    #expect(
                        target.resource.kind == .ttmScript || target.resource.kind == .bitmap,
                        "\(entry.name) reference '\(ref.name)' has unexpected kind \(target.resource.kind)"
                    )
                }
            }
        }
    }

    @Test("Expected canonical ADS scripts are present")
    func expectedCanonicalScripts() throws {
        let archive = try ContainerTests.archive()
        // From `story_data.h` in jc_reborn — the ADS files the engine schedules from.
        let expected = [
            "ACTIVITY.ADS", "BUILDING.ADS", "FISHING.ADS", "JOHNNY.ADS",
            "MARY.ADS", "MISCGAG.ADS", "STAND.ADS", "SUZY.ADS",
            "VISITOR.ADS", "WALKSTUF.ADS",
        ]
        for name in expected {
            let entry = archive.entry(named: name)
            #expect(entry != nil, "missing canonical ADS '\(name)'")
            if let entry {
                #expect(entry.resource.kind == .adsScript, "\(name) wrong kind")
            }
        }
    }
}
