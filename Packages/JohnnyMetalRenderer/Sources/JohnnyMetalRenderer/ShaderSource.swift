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

// ShaderSource.swift
//
// Metal shader source compiled at runtime via MTLDevice.makeLibrary(source:options:).
// Compiling from source avoids the need for a pre-built .metallib in the
// SwiftPM package, while giving both the debug app and the .saver access to
// the same shaders. Compilation takes ~10–20 ms at init time — acceptable for
// a screensaver.
//
// Pipeline overview:
//   Vertex: fullscreen triangle strip (4 vertices, no vertex buffer),
//           clipped to the integer-scaled game rect via uniform gameRect.
//   Fragment: R8Uint framebuffer index → 16×1 RGBA palette LUT → output colour.
//
// Shader design notes:
//   - Palette indices 0–15 map to RGBA8 entries in the 16×1 palette texture.
//   - Index 0xFF (transparency sentinel, see Framebuffer.swift) is mapped to
//     black (0,0,0,1). By the time the composed framebuffer reaches the
//     renderer the background should have filled every pixel, so this branch
//     is rarely taken in practice.
//   - Integer-format textures (R8Uint) require access::read and pixel-space
//     coordinates; normalised UV coordinates from the interpolator are
//     multiplied by (640, 480) and clamped before the read.

internal let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

// -----------------------------------------------------------------------
// Shared types
// -----------------------------------------------------------------------

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

/// Game area corners in Metal NDC: (left, top, right, bottom).
/// NDC x ∈ [-1, 1]: -1 = left, +1 = right.
/// NDC y ∈ [-1, 1]: -1 = bottom, +1 = top.
struct Uniforms {
    float4 gameRect;
};

// -----------------------------------------------------------------------
// Vertex shader — fullscreen triangle strip with integer-scale letterbox
// -----------------------------------------------------------------------

/// Emit a quad as a triangle strip (4 vertices, no vertex buffer).
///
/// Vertex layout by vertexID (triangle strip topology):
///   0 = top-left,  1 = top-right
///   2 = bottom-left, 3 = bottom-right
///
/// UV (0,0) = top-left of image; (1,1) = bottom-right (standard texture space).
vertex VertexOut vertexShader(
    uint vertexID [[vertex_id]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    // Decompose vertex ID into UV via bit manipulation:
    //   u = bit 0 of vertexID (0 = left, 1 = right)
    //   v = bit 1 of vertexID (0 = top,  1 = bottom)
    float u = float(vertexID & 1u);
    float v = float((vertexID >> 1u) & 1u);

    // Map UV to NDC using the letterbox rect.
    // gameRect.x = NDC left,  gameRect.z = NDC right
    // gameRect.y = NDC top,   gameRect.w = NDC bottom
    float ndcX = mix(uniforms.gameRect.x, uniforms.gameRect.z, u);
    float ndcY = mix(uniforms.gameRect.y, uniforms.gameRect.w, v);

    VertexOut out;
    out.position = float4(ndcX, ndcY, 0.0, 1.0);
    out.texCoord = float2(u, v);
    return out;
}

// -----------------------------------------------------------------------
// Fragment shader — palette LUT lookup
// -----------------------------------------------------------------------

/// Map each fragment's UV to a source pixel index, look it up in the
/// 16-entry RGBA palette, and output the colour.
fragment float4 fragmentShader(
    VertexOut in [[stage_in]],
    texture2d<uint, access::read> framebuffer [[texture(0)]],
    texture2d<float, access::read> palette    [[texture(1)]]
) {
    // Integer pixel coordinate within the 640×480 source framebuffer.
    // Clamped to [0,639] × [0,479] to guard against floating-point edge values.
    uint2 px = min(uint2(in.texCoord * float2(640.0, 480.0)), uint2(639, 479));

    uint  idx  = framebuffer.read(px).r;

    // 0xFF is the transparency sentinel; map it to black rather than an
    // out-of-bounds palette read.
    if (idx >= 16u) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    return palette.read(uint2(idx, 0u));
}
"""
