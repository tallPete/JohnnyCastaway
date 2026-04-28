// TestResources.swift
//
// Locates the canonical Sierra resource files for use in tests.
// These files are user-provided IP; they are not committed to the
// repository. Tests that need them are conditionally disabled when
// the files are not located, with a message explaining how to point
// the suite at them.
//
// Lookup order:
//   1. Environment variable `JOHNNY_RESOURCES_DIR` — absolute path to
//      a directory containing RESOURCE.MAP and RESOURCE.001.
//   2. Walk upward from this source file looking for a `Resources/`
//      directory that contains RESOURCE.MAP. This finds the canonical
//      set placed at the repo root by the developer.

import Foundation
import Testing

enum TestResources {

    /// Located resources directory, or nil if not found.
    static let directory: URL? = locate()

    static var available: Bool { directory != nil }

    /// Skip-message used by `.disabled(if:)` traits when resources are absent.
    static let skipMessage: Comment = """
        Canonical Sierra resource files not located. \
        Set JOHNNY_RESOURCES_DIR=/path/to/dir or place RESOURCE.MAP \
        and RESOURCE.001 at <repo-root>/Resources/.
        """

    /// Lazily-loaded RESOURCE.MAP bytes.
    static let mapData: Data? = directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("RESOURCE.MAP")) }

    /// Lazily-loaded RESOURCE.001 bytes.
    static let containerData: Data? = directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("RESOURCE.001")) }

    private static func locate() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let envPath = env["JOHNNY_RESOURCES_DIR"] {
            let url = URL(fileURLWithPath: envPath, isDirectory: true)
            if hasCanonicalFiles(at: url) { return url }
        }

        // Walk upward from this file looking for a Resources/ dir.
        var dir = URL(fileURLWithPath: #filePath, isDirectory: false).deletingLastPathComponent()
        let fm = FileManager.default
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Resources", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue,
               hasCanonicalFiles(at: candidate) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    private static func hasCanonicalFiles(at dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("RESOURCE.MAP").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("RESOURCE.001").path)
    }
}
