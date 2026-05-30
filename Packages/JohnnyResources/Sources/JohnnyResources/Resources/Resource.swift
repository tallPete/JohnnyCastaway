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

// Resource.swift
//
// Sum type over the parsed payloads of every resource entry in the
// container. The container also includes a `.VIN` entry that none of
// the prior ports interpret; we preserve it as `.unrecognised` rather
// than raising.

import Foundation

public enum Resource: Sendable, Equatable {
    case palette(Palette)
    case screen(Screen)
    case bitmap(Bitmap)
    case ttmScript(TTMScript)
    case adsScript(ADSScript)

    /// An entry whose extension wasn't one of `.PAL .SCR .BMP .TTM .ADS`.
    /// In the canonical container this is `FILES.VIN`. The raw bytes
    /// (everything after the 13-byte name + uint32 declared-size header)
    /// are preserved.
    case unrecognised(extension: String, rawData: Data)

    public var kind: ResourceKind {
        switch self {
        case .palette:     return .palette
        case .screen:      return .screen
        case .bitmap:      return .bitmap
        case .ttmScript:   return .ttmScript
        case .adsScript:   return .adsScript
        case .unrecognised: return .unrecognised
        }
    }
}

public enum ResourceKind: String, Sendable, CaseIterable {
    case palette        // .PAL
    case screen         // .SCR
    case bitmap         // .BMP
    case ttmScript      // .TTM
    case adsScript      // .ADS
    case unrecognised   // .VIN, etc.

    /// Map a 4-character extension (including the dot) to its kind.
    /// Returns nil for extensions we do not recognise.
    public static func fromExtension(_ ext: String) -> ResourceKind? {
        switch ext.uppercased() {
        case ".PAL": return .palette
        case ".SCR": return .screen
        case ".BMP": return .bitmap
        case ".TTM": return .ttmScript
        case ".ADS": return .adsScript
        default:     return nil
        }
    }
}
