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

// EngineFixtures.swift
//
// Test infrastructure for JohnnyEngineTests. Provides a lazily-loaded
// ResourceArchive from the canonical Sierra resource files, mirrors the
// pattern used in JohnnyResources/Tests/TestResources.swift, and adds an
// Engine builder for engine-level tests.
//
// Resource-file location: same walk-up-from-#filePath strategy. The
// Resources/ dir lives at the repo root, three levels up from here:
//   Packages/JohnnyEngine/Tests/JohnnyEngineTests/Helpers/EngineFixtures.swift
//                 ↑          ↑         ↑
//               root

import Foundation
import Testing
import JohnnyResources
@testable import JohnnyEngine

// MARK: - EngineTestResources

enum EngineTestResources {

    static let directory: URL? = locate()
    static var available: Bool { directory != nil }

    static let skipMessage: Comment = """
        Canonical Sierra resource files not located. \
        Set JOHNNY_RESOURCES_DIR=/path/to/dir or place RESOURCE.MAP \
        and RESOURCE.001 at <repo-root>/Resources/.
        """

    // Cached parse result
    private static let archiveResult: Result<ResourceArchive, Error> = {
        guard let dir = directory,
              let mapData = try? Data(contentsOf: dir.appendingPathComponent("RESOURCE.MAP")),
              let conData = try? Data(contentsOf: dir.appendingPathComponent("RESOURCE.001")) else {
            return .failure(NSError(domain: "EngineFixtures", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "resource files not available"]))
        }
        return Result { try ResourceArchive.parse(map: mapData, container: conData) }
    }()

    static func archive() throws -> ResourceArchive {
        try archiveResult.get()
    }

    static func engine() throws -> Engine {
        try Engine(archive: try archive())
    }

    // MARK: - Private

    private static func locate() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["JOHNNY_RESOURCES_DIR"] {
            let url = URL(fileURLWithPath: p, isDirectory: true)
            if hasFiles(at: url) { return url }
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm  = FileManager.default
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Resources", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue,
               hasFiles(at: candidate) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    private static func hasFiles(at dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("RESOURCE.MAP").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("RESOURCE.001").path)
    }
}
