// EngineRenderer.swift
//
// Core Metal renderer for JohnnyEngine output.
//
// Responsibilities:
//   1. Own the MTLDevice, MTLCommandQueue, and render pipeline state.
//   2. Upload the engine's 640×480 indexed framebuffer to an R8Uint texture
//      and its 16-entry palette to an RGBA8Unorm 16×1 texture.
//   3. Render a single textured quad (via triangle strip) to a CAMetalDrawable,
//      applying nearest-neighbour integer-scaled letterboxing via the
//      `gameRect` uniform.
//
// Texture strategy:
//   Both textures use MTLStorageModeShared (unified memory on Apple Silicon).
//   CPU writes via replace(region:…) are immediately visible to the GPU in the
//   command buffer committed in the same frame — no explicit synchronisation
//   needed because the CPU write completes before makeCommandBuffer() is called.
//   This avoids double-buffering complexity at the cost of theoretically tearing
//   on Intel, which is acceptable for our ~25 Hz update rate.
//
// Letterboxing:
//   Integer scale k = floor(min(W/640, H/480)), minimum 1.
//   Game rect is centred in the drawable; remaining area is cleared to black.

import Metal
import QuartzCore
import JohnnyEngine

// MARK: - Error type

public enum RendererError: Error, CustomStringConvertible {
    case noCommandQueue
    case shaderCompilationFailed(String)
    case shaderFunctionNotFound(String)
    case textureCreationFailed
    case pipelineCreationFailed(String)

    public var description: String {
        switch self {
        case .noCommandQueue:                return "Failed to create MTLCommandQueue"
        case .shaderCompilationFailed(let m): return "Shader compilation failed: \(m)"
        case .shaderFunctionNotFound(let n):  return "Shader function not found: \(n)"
        case .textureCreationFailed:         return "Failed to create MTLTexture"
        case .pipelineCreationFailed(let m): return "Pipeline creation failed: \(m)"
        }
    }
}

// MARK: - Uniforms (matches Metal Uniforms struct — float4, 16 bytes, 16-byte aligned)

private struct Uniforms {
    /// (left, top, right, bottom) in Metal NDC [-1, 1].
    /// NDC +y = up; so top > bottom.
    var gameRect: SIMD4<Float>
}

// MARK: - EngineRenderer

/// Pure Metal renderer: takes a Framebuffer + EnginePalette, draws to a drawable.
///
/// Not thread-safe. Call all methods from the same thread (typically the main
/// thread, driven by JohnnyMetalView's CADisplayLink).
public final class EngineRenderer {

    // ---------------------------------------------------------------
    // MARK: Metal state
    // ---------------------------------------------------------------

    private let device:        MTLDevice
    private let commandQueue:  MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    // R8Uint 640×480 — one byte per pixel, value = palette index (0..15 or 0xFF)
    private let framebufferTexture: MTLTexture

    // RGBA8Unorm 16×1 — one RGBA entry per palette colour
    private let paletteTexture: MTLTexture

    // ---------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------

    public init(device: MTLDevice) throws {
        self.device = device

        // Command queue
        guard let cq = device.makeCommandQueue() else {
            throw RendererError.noCommandQueue
        }
        self.commandQueue = cq

        // Compile shaders from embedded source
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: metalShaderSource, options: nil)
        } catch {
            throw RendererError.shaderCompilationFailed(error.localizedDescription)
        }

        guard let vertFn = library.makeFunction(name: "vertexShader") else {
            throw RendererError.shaderFunctionNotFound("vertexShader")
        }
        guard let fragFn = library.makeFunction(name: "fragmentShader") else {
            throw RendererError.shaderFunctionNotFound("fragmentShader")
        }

        // Render pipeline
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.label                              = "JohnnyPaletteLUT"
        pipelineDesc.vertexFunction                     = vertFn
        pipelineDesc.fragmentFunction                   = fragFn
        pipelineDesc.colorAttachments[0].pixelFormat    = .bgra8Unorm

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            throw RendererError.pipelineCreationFailed(error.localizedDescription)
        }

        // Framebuffer texture: R8Uint 640×480
        let fbDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint,
            width:  Framebuffer.width,
            height: Framebuffer.height,
            mipmapped: false
        )
        fbDesc.usage       = [.shaderRead]
        fbDesc.storageMode = .shared
        guard let fbTex = device.makeTexture(descriptor: fbDesc) else {
            throw RendererError.textureCreationFailed
        }
        self.framebufferTexture = fbTex

        // Palette texture: RGBA8Unorm 16×1
        let palDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width:  16,
            height: 1,
            mipmapped: false
        )
        palDesc.usage       = [.shaderRead]
        palDesc.storageMode = .shared
        guard let palTex = device.makeTexture(descriptor: palDesc) else {
            throw RendererError.textureCreationFailed
        }
        self.paletteTexture = palTex
    }

    // ---------------------------------------------------------------
    // MARK: Upload
    // ---------------------------------------------------------------

    /// Upload the engine's current framebuffer and palette to GPU textures.
    ///
    /// Call once per engine tick (before `render`). The upload completes
    /// synchronously on the CPU; the GPU sees the new data in the command
    /// buffer committed by the subsequent `render` call.
    public func update(framebuffer: Framebuffer, palette: EnginePalette) {
        // Framebuffer: raw indexed pixels → R8Uint texture
        framebuffer.pixels.withUnsafeBytes { ptr in
            framebufferTexture.replace(
                region:      MTLRegionMake2D(0, 0, Framebuffer.width, Framebuffer.height),
                mipmapLevel: 0,
                withBytes:   ptr.baseAddress!,
                bytesPerRow: Framebuffer.width   // 1 byte per pixel, no padding
            )
        }

        // Palette: [RGBA …] × 16 → RGBA8Unorm texture
        var paletteBytes = [UInt8]()
        paletteBytes.reserveCapacity(16 * 4)
        for c in palette.colors {
            paletteBytes.append(c.r)
            paletteBytes.append(c.g)
            paletteBytes.append(c.b)
            paletteBytes.append(c.a)
        }
        paletteBytes.withUnsafeBytes { ptr in
            paletteTexture.replace(
                region:      MTLRegionMake2D(0, 0, 16, 1),
                mipmapLevel: 0,
                withBytes:   ptr.baseAddress!,
                bytesPerRow: 16 * 4              // 4 bytes per entry
            )
        }
    }

    // ---------------------------------------------------------------
    // MARK: Render
    // ---------------------------------------------------------------

    /// Encode and submit a render pass to the given drawable.
    ///
    /// Clears the drawable to black, then draws the game quad with integer
    /// scaling and letterboxing. Call `update` before each call to `render`
    /// when the engine has ticked; call `render` every display frame to
    /// present smoothly at native refresh rate.
    public func render(to drawable: CAMetalDrawable, drawableSize: CGSize) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture     = drawable.texture
        passDesc.colorAttachments[0].loadAction  = .clear
        passDesc.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            commandBuffer.commit()
            return
        }

        encoder.setRenderPipelineState(pipelineState)

        var uniforms = Uniforms(gameRect: Self.gameRect(for: drawableSize))
        encoder.setVertexBytes(&uniforms,
                               length: MemoryLayout<Uniforms>.stride,
                               index: 0)

        encoder.setFragmentTexture(framebufferTexture, index: 0)
        encoder.setFragmentTexture(paletteTexture,    index: 1)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // ---------------------------------------------------------------
    // MARK: Letterbox geometry (public for unit testing)
    // ---------------------------------------------------------------

    /// Compute the NDC game rectangle for a drawable of the given size.
    ///
    /// Returns `SIMD4<Float>(left, top, right, bottom)` in Metal NDC
    /// (x ∈ [-1,1], y ∈ [-1,1] with +y upward).
    ///
    /// Integer scale: `k = floor(min(W/640, H/480))`, minimum 1.
    /// The game area is centred; the surrounding margin is cleared to black
    /// by the render pass clear colour.
    public static func gameRect(for drawableSize: CGSize) -> SIMD4<Float> {
        let dw = Double(drawableSize.width)
        let dh = Double(drawableSize.height)

        // Integer scale, at least 1× so tiny windows still show something
        let k  = max(1.0, floor(min(dw / 640.0, dh / 480.0)))
        let gw = 640.0 * k
        let gh = 480.0 * k

        // Pixel-space offset of the game rect's top-left corner
        let ox = (dw - gw) / 2.0
        let oy = (dh - gh) / 2.0

        // Convert to NDC (x: [-1,1] left-to-right; y: [1,-1] top-to-bottom)
        let left   = Float(ox / dw * 2.0 - 1.0)
        let right  = Float((ox + gw) / dw * 2.0 - 1.0)
        let top    = Float(1.0 - oy / dh * 2.0)
        let bottom = Float(1.0 - (oy + gh) / dh * 2.0)

        return SIMD4<Float>(left, top, right, bottom)
    }
}
