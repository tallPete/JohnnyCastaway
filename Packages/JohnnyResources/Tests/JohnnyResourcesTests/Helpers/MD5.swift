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

// MD5.swift
//
// Tiny MD5 helper backed by CryptoKit. Used by tests to snapshot-pin
// the byte signatures of decompressed payloads, so a future change
// that subtly perturbs the parser output is caught immediately.

import Foundation
import CryptoKit

enum MD5Hash {

    /// Lower-case hex string of MD5(data).
    static func hex(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
