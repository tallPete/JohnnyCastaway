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

// PNGEncoder.swift
//
// Encode an `RGBAImage` to a PNG file using ImageIO. Used by the
// diagnostic test that dumps a few canonical scenes to /tmp so the
// developer can visually confirm the parser extracts recognisable
// imagery.

import Foundation
import ImageIO
import UniformTypeIdentifiers
import JohnnyResources

enum PNGEncoder {

    enum Error: Swift.Error {
        case dataProviderInitFailed
        case cgImageInitFailed
        case destinationInitFailed
        case finalizeFailed
    }

    /// Write `image` to `url` as a PNG. Overwrites any existing file.
    static func write(_ image: RGBAImage, to url: URL) throws {
        let bytesPerRow = image.width * 4
        guard let provider = CGDataProvider(data: image.pixels as CFData) else {
            throw Error.dataProviderInitFailed
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw Error.cgImageInitFailed
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw Error.destinationInitFailed
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw Error.finalizeFailed
        }
    }
}
