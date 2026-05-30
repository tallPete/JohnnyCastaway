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

// ContainerTests.swift
//
// Tests against the canonical RESOURCE.001 (MD5
// 8bb6c99e9129806b5089a39d24228a36, 1,175,645 bytes) parsed via
// `ResourceArchive.parse`.

import Testing
import Foundation
@testable import JohnnyResources

@Suite("ResourceArchive (canonical container)",
       .disabled(if: !TestResources.available, TestResources.skipMessage))
struct ContainerTests {

    /// Cached parse so we don't re-decompress every blob per test.
    /// Stored as a `Result` so the actual parse error surfaces on
    /// access rather than getting swallowed by `try?`.
    static let archiveResult: Result<ResourceArchive, Error> = {
        guard let mapData = TestResources.mapData,
              let containerData = TestResources.containerData else {
            return .failure(
                NSError(
                    domain: "TestResources", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Canonical resources not located"]
                )
            )
        }
        do {
            return .success(try ResourceArchive.parse(map: mapData, container: containerData))
        } catch {
            return .failure(error)
        }
    }()

    /// Convenience: throws the underlying parse error if the archive
    /// failed to load.
    static func archive() throws -> ResourceArchive {
        try archiveResult.get()
    }

    @Test("Canonical container has the expected MD5")
    func canonicalFileMD5() throws {
        let data = try #require(TestResources.containerData)
        #expect(data.count == 1_175_645)
        #expect(MD5Hash.hex(data) == "8bb6c99e9129806b5089a39d24228a36")
    }

    @Test("Container parses cleanly (no thrown errors)")
    func parsesWithoutError() throws {
        let archive = try Self.archive()
        #expect(archive.entries.count == 180)
    }

    @Test("Every entry has a non-empty 13-byte resource name")
    func everyEntryHasName() throws {
        let archive = try Self.archive()
        for entry in archive.entries {
            #expect(!entry.name.isEmpty, "empty name at offset \(entry.containerOffset)")
            #expect(entry.name.count <= 12, "name '\(entry.name)' too long")
        }
    }

    @Test("Resource names are unique")
    func namesUnique() throws {
        let archive = try Self.archive()
        let names = archive.entries.map { $0.name.uppercased() }
        let unique = Set(names)
        #expect(names.count == unique.count, "duplicate names found")
    }

    @Test("Each entry's parsed kind matches its filename extension")
    func kindMatchesExtension() throws {
        let archive = try Self.archive()
        for entry in archive.entries {
            let ext = String(entry.name.suffix(4)).uppercased()
            let expected = ResourceKind.fromExtension(ext) ?? .unrecognised
            #expect(
                entry.resource.kind == expected,
                "entry '\(entry.name)': kind \(entry.resource.kind) != expected \(expected)"
            )
        }
    }

    @Test("Container-declared size is non-zero and not absurdly large")
    func containerDeclaredSizeReasonable() throws {
        let archive = try Self.archive()
        // The MAP's "length" field is a known-bogus value (read but
        // never used by the C reference), so we don't cross-check
        // against it. The container's own declared size is the only
        // length we have, and even it isn't actually consulted by
        // any parser — it's preserved for round-trip fidelity. Just
        // check it's not absurd.
        for entry in archive.entries {
            #expect(entry.containerDeclaredSize > 0, "\(entry.name) declared size = 0")
            #expect(
                entry.containerDeclaredSize < 1_000_000,
                "\(entry.name) declared size = \(entry.containerDeclaredSize) (suspiciously large)"
            )
        }
    }

    @Test("Resource counts: ≥ 1 PAL, ≥ 1 SCR, ≥ 1 BMP, ≥ 1 TTM, ≥ 1 ADS, exactly 1 unrecognised (.VIN)")
    func resourceCountsByKind() throws {
        let archive = try Self.archive()
        let palettes = archive.entries(of: .palette)
        let screens = archive.entries(of: .screen)
        let bitmaps = archive.entries(of: .bitmap)
        let ttms = archive.entries(of: .ttmScript)
        let adss = archive.entries(of: .adsScript)
        let unrecognised = archive.entries(of: .unrecognised)

        #expect(palettes.count >= 1)
        #expect(screens.count >= 1)
        #expect(bitmaps.count >= 1)
        #expect(ttms.count >= 1)
        #expect(adss.count >= 1)
        #expect(unrecognised.count == 1, "expected exactly 1 unrecognised entry (FILES.VIN)")

        // The unrecognised entry should be FILES.VIN.
        if let only = unrecognised.first {
            #expect(only.name == "FILES.VIN", "unrecognised entry name: \(only.name)")
        }

        // Sum should equal total.
        let sum = palettes.count + screens.count + bitmaps.count + ttms.count + adss.count + unrecognised.count
        #expect(sum == archive.entries.count)
    }

    @Test("Lookup by name (case-insensitive) finds known entries")
    func entryLookup() throws {
        let archive = try Self.archive()
        // FILES.VIN is the only resource we can confidently name without
        // having read the canonical entry list yet; it's verified above.
        #expect(archive.entry(named: "files.vin") != nil)
        #expect(archive.entry(named: "FILES.VIN") != nil)
        #expect(archive.entry(named: "Files.Vin") != nil)
        #expect(archive.entry(named: "DOES_NOT_EXIST.XYZ") == nil)
    }
}
