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

// EnginePNGDump.swift
//
// Write a JohnnyEngine Framebuffer to a PNG file for visual review.
// Uses ImageIO directly (same approach as PNGEncoder in JohnnyResources)
// but works with indexed 8-bit framebuffers by converting through an
// EnginePalette to RGBA on the way out.

import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import JohnnyEngine

enum EnginePNGDump {

    enum Error: Swift.Error {
        case providerInitFailed
        case cgImageInitFailed
        case destInitFailed
        case finalizeFailed
    }

    /// Convert a Framebuffer to RGBA using `palette`, then write to `url`.
    static func write(
        _ framebuffer: Framebuffer,
        palette: EnginePalette,
        to url: URL
    ) throws {
        var rgba = [UInt8]()
        rgba.reserveCapacity(Framebuffer.width * Framebuffer.height * 4)
        for idx in framebuffer.pixels {
            if idx == 0xFF {
                rgba += [0, 0, 0, 255]   // transparent → black for PNG dump
            } else {
                let c = palette.colors[Int(idx) & 0x0F]
                rgba += [c.r, c.g, c.b, 255]
            }
        }
        let data = Data(rgba)

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw Error.providerInitFailed
        }
        let space      = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = CGImage(
            width: Framebuffer.width,
            height: Framebuffer.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: Framebuffer.width * 4,
            space: space,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { throw Error.cgImageInitFailed }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1, nil
        ) else { throw Error.destInitFailed }

        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw Error.finalizeFailed }
    }
}
