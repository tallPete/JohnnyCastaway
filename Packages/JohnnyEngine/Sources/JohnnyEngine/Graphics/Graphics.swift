// Graphics.swift
//
// Software rasterisation for the engine layer system. Translates
// graphics.c from jc_reborn, replacing SDL surfaces with Framebuffer
// and the sentinel-index transparency scheme.
//
// Key deviations from graphics.c:
//  • No 32bpp RGBA; pixels are indexed 0xFF = transparent.
//  • `grLoadScreen` / `grLoadBmp` are handled by TTMInterpreter directly
//    (they need ResourceCache); Graphics only owns the draw primitives,
//    offsets, and the saved-zones layer.
//  • grFadeOut() is deferred to Phase 7 (it's a visual transition effect
//    on the display, not needed for the interpreter logic).
//
// Drawing coordinate system: all public methods accept coordinates in
// "TTM space" (relative to the layer's top-left corner); they apply
// the dx/dy offset before calling into the layer. This matches the C
// `x += grDx; y += grDy;` pattern in every draw function.

import Foundation
import JohnnyResources

/// Holds the mutable drawing state shared across all TTM threads in
/// one ADS run: the x/y offset applied to all draw calls, the saved-
/// zones layer (SAVE_ZONE / RESTORE_ZONE), and the one method that
/// composites all layers into the final framebuffer.
public final class GraphicsState: @unchecked Sendable {

    // ---------------------------------------------------------------
    // MARK: Global offset — translation of `grDx` / `grDy`
    // ---------------------------------------------------------------

    /// X offset added to every draw call. Set to the island's X
    /// position for scenes that render on the island.
    public var dx: Int = 0

    /// Y offset added to every draw call.
    public var dy: Int = 0

    /// True iff the current background is the regular ocean-island
    /// background (set up by IslandRenderer.setup), as opposed to a
    /// scene-specific screen loaded via the LOAD_SCREEN TTM opcode (e.g.
    /// ISLAND2.SCR for a fishing close-up). The wave-animation thread only
    /// makes sense over the island background — running it over a scene's
    /// own background draws wave sprites at meaningless positions.
    public var isIslandBackground: Bool = false

    // ---------------------------------------------------------------
    // MARK: Saved-zones layer — translation of `grSavedZonesLayer`
    // ---------------------------------------------------------------

    /// A persistent layer that accumulates COPY_ZONE_TO_BG results.
    /// Composited between the background and the TTM thread layers,
    /// exactly like the SDL savedZonesLayer in graphics.c.
    /// nil == no saved zones yet.
    var savedZonesLayer: Framebuffer? = nil

    // ---------------------------------------------------------------
    // MARK: Background — translation of `grBackgroundSfc`
    // ---------------------------------------------------------------

    /// The full-screen indexed background, loaded by LOAD_SCREEN.
    /// nil == black / transparent background.
    var background: Framebuffer? = nil

    // ---------------------------------------------------------------
    // MARK: Transparent colour key
    // ---------------------------------------------------------------

    /// Palette index treated as transparent in all sprite blits.
    /// jc_reborn uses SDL_SetColorKey with VGA palette index 5 (r=42,g=0,b=42
    /// in 6-bit → R=0xa8,G=0,B=0xa8 in 8-bit — magenta). Every sprite sheet
    /// has its background filled with this colour, so we must skip index 5 just
    /// as the C reference skips the SDL color key.
    public var transparentIndex: UInt8 = 5

    // ---------------------------------------------------------------
    // MARK: Draw primitives
    // ---------------------------------------------------------------

    /// Plot a single pixel (x, y are TTM coords; dx/dy applied).
    /// Translates grDrawPixel() in graphics.c:288–291.
    func drawPixel(
        on layer: inout Framebuffer,
        x: Int, y: Int,
        color: UInt8
    ) {
        layer.putPixel(x: x + dx, y: y + dy, color: color)
    }

    /// Draw a line from (x1,y1) to (x2,y2) using Bresenham's algorithm.
    /// Pixel-perfect match to grDrawLine() in graphics.c:295–350.
    func drawLine(
        on layer: inout Framebuffer,
        x1 inX1: Int, y1 inY1: Int,
        x2 inX2: Int, y2 inY2: Int,
        color: UInt8
    ) {
        let x1 = inX1 + dx, y1 = inY1 + dy
        let x2 = inX2 + dx, y2 = inY2 + dy

        let absDx = abs(x2 - x1)
        let absDy = abs(y2 - y1)
        let xinc  = x2 > x1 ?  1 : -1
        let yinc  = y2 > y1 ?  1 : -1

        var x = x1, y = y1

        if absDy < absDx {
            var cumul = (absDx + 1) >> 1
            for _ in 0 ..< absDx {
                layer.putPixel(x: x, y: y, color: color)
                x += xinc
                cumul += absDy
                if cumul > absDx {
                    cumul -= absDx
                    y += yinc
                }
            }
        } else {
            var cumul = (absDy + 1) >> 1
            for _ in 0 ..< absDy {
                layer.putPixel(x: x, y: y, color: color)
                y += yinc
                cumul += absDx
                if cumul > absDy {
                    cumul -= absDy
                    x += xinc
                }
            }
        }
    }

    /// Fill a rectangle.
    /// Translates grDrawRect() in graphics.c:353–366.
    /// NOTE: In grDrawRect() the 3rd/4th args are width/height (not x2/y2).
    func drawRect(
        on layer: inout Framebuffer,
        x inX: Int, y inY: Int,
        width: Int, height: Int,
        color: UInt8
    ) {
        let clip = layer.clipRect
        let x1 = max(inX + dx, clip.x1)
        let y1 = max(inY + dy, clip.y1)
        let x2 = min(inX + dx + width,  clip.x2)
        let y2 = min(inY + dy + height, clip.y2)
        guard x1 < x2, y1 < y2 else { return }
        for row in y1 ..< y2 {
            let base = row * Framebuffer.width
            for col in x1 ..< x2 {
                layer.pixels[base + col] = color
            }
        }
    }

    /// Draw a Bresenham circle / disc.
    /// Translates grDrawCircle() in graphics.c:369–453.
    /// args: (x1, y1) is the top-left corner; width/height are the
    /// bounding box. Only square circles (width == height, even) are
    /// supported — matches the original guard clauses.
    func drawCircle(
        on layer: inout Framebuffer,
        x1 inX1: Int, y1 inY1: Int,
        width: Int, height: Int,
        fgColor: UInt8, bgColor: UInt8
    ) {
        guard width == height else { return } // can't draw ellipse
        guard width % 2 == 0 else { return }  // odd diameter not supported

        let x1 = inX1 + dx, y1 = inY1 + dy
        let r  = (width >> 1) - 1
        let xc = x1 + r
        let yc = y1 + r

        var px = 0, py = r
        var d  = 1 - r

        // Fill interior with bgColor
        while true {
            drawHLine(on: &layer, x1: xc - px, x2: xc + px + 1, y: yc + py + 1, color: bgColor)
            drawHLine(on: &layer, x1: xc - px, x2: xc + px + 1, y: yc - py,     color: bgColor)
            drawHLine(on: &layer, x1: xc - py, x2: xc + py + 1, y: yc + px + 1, color: bgColor)
            drawHLine(on: &layer, x1: xc - py, x2: xc + py + 1, y: yc - px,     color: bgColor)
            if py - px <= 1 { break }
            if d < 0 {
                d += (px << 1) + 3
            } else {
                d += ((px - py) << 1) + 5
                py -= 1
            }
            px += 1
        }

        // Outline with fgColor (only if different from bgColor)
        if fgColor != bgColor {
            px = 0; py = r; d = 1 - r
            while true {
                layer.putPixel(x: xc - px,     y: yc + py + 1, color: fgColor)
                layer.putPixel(x: xc + px + 1, y: yc + py + 1, color: fgColor)
                layer.putPixel(x: xc - px,     y: yc - py,     color: fgColor)
                layer.putPixel(x: xc + px + 1, y: yc - py,     color: fgColor)
                layer.putPixel(x: xc - py,     y: yc + px + 1, color: fgColor)
                layer.putPixel(x: xc + py + 1, y: yc + px + 1, color: fgColor)
                layer.putPixel(x: xc - py,     y: yc - px,     color: fgColor)
                layer.putPixel(x: xc + py + 1, y: yc - px,     color: fgColor)
                if py - px <= 1 { break }
                if d < 0 {
                    d += (px << 1) + 3
                } else {
                    d += ((px - py) << 1) + 5
                    py -= 1
                }
                px += 1
            }
        }
    }

    // ---------------------------------------------------------------
    // MARK: Sprite blit
    // ---------------------------------------------------------------

    /// Blit sprite (spriteNo, imageNo) at (x, y) from a loaded Bitmap.
    /// Translates grDrawSprite() in graphics.c:456–469.
    ///
    /// `imageNo` is the BMP-slot index that was already used by the caller
    /// to pick `bitmap`; we accept it for parity with the bytecode but the
    /// only real validation is that `spriteNo` is in range for the bitmap's
    /// sprite-frame count.  An earlier version checked
    /// `imageNo < bitmap.imageCount`, which is a category error: imageNo is
    /// a slot index (0–5), bitmap.imageCount is the number of sprite frames
    /// packed into the bitmap.  When the two coincided (small imageNo, many
    /// frames) the guard happened to pass; when a bitmap with few frames
    /// was loaded into a high-numbered slot, all draws silently dropped
    /// (symptom: missing sleep-Z animation, missing fire frames).  Matches
    /// jc_reborn graphics.c:457 (`spriteNo >= numSprites[imageNo]`) and
    /// Go port graphics.go:476.
    func drawSprite(
        on layer: inout Framebuffer,
        bitmap: Bitmap,
        x inX: Int, y inY: Int,
        spriteNo: Int, imageNo: Int
    ) {
        guard spriteNo >= 0, spriteNo < bitmap.imageCount else { return }
        let bx = inX + dx
        let by = inY + dy
        let w  = Int(bitmap.widths[spriteNo])
        let h  = Int(bitmap.heights[spriteNo])
        let spritePixels = bitmap.pixels(forSprite: spriteNo)
        let clip = layer.clipRect
        for row in 0 ..< h {
            let dy2 = by + row
            guard dy2 >= clip.y1 && dy2 < clip.y2 else { continue }
            for col in 0 ..< w {
                let dx2 = bx + col
                guard dx2 >= clip.x1 && dx2 < clip.x2 else { continue }
                let px = spritePixels[row * w + col]
                if px != 0xFF && px != transparentIndex {
                    layer.pixels[dy2 * Framebuffer.width + dx2] = px
                }
            }
        }
    }

    /// Blit sprite horizontally flipped at (x, y).
    /// Translates grDrawSpriteFlip() in graphics.c:472–491.
    /// See drawSprite(...) for the imageNo / spriteNo guard rationale.
    func drawSpriteFlip(
        on layer: inout Framebuffer,
        bitmap: Bitmap,
        x inX: Int, y inY: Int,
        spriteNo: Int, imageNo: Int
    ) {
        guard spriteNo >= 0, spriteNo < bitmap.imageCount else { return }
        let w  = Int(bitmap.widths[spriteNo])
        let h  = Int(bitmap.heights[spriteNo])
        // flip: x coordinate starts at right edge (x + w - 1), column 0 lands there
        let bx = (inX + dx) + (w - 1)
        let by = inY + dy
        let spritePixels = bitmap.pixels(forSprite: spriteNo)
        let clip = layer.clipRect
        for row in 0 ..< h {
            let dy2 = by + row
            guard dy2 >= clip.y1 && dy2 < clip.y2 else { continue }
            for col in 0 ..< w {
                let dx2 = bx - col    // mirror x
                guard dx2 >= clip.x1 && dx2 < clip.x2 else { continue }
                let px = spritePixels[row * w + col]
                if px != 0xFF && px != transparentIndex {
                    layer.pixels[dy2 * Framebuffer.width + dx2] = px
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // MARK: Layer management — translate grNewLayer / grClearScreen
    // ---------------------------------------------------------------

    /// Create a new transparent layer (all pixels = 0xFF sentinel).
    /// Translates grNewLayer() in graphics.c:218–225.
    static func newLayer() -> Framebuffer {
        Framebuffer(filledWith: 0xFF)
    }

    /// Clear a layer's content to transparent, restoring the clip rect.
    /// Translates grClearScreen() in graphics.c:494–502: it temporarily
    /// disables the clip rect (SDL_SetClipRect NULL), fills the WHOLE
    /// surface, then restores the clip. Clearing only within the clip leaves
    /// stale pixels outside it — which is what was producing "multiple
    /// Johnnys" (old animation frames staying behind when the script set a
    /// tight clip zone around the new sprite position).
    func clearScreen(layer: inout Framebuffer) {
        let saved = layer.clipRect
        layer.clearAll(to: 0xFF)
        layer.clipRect = saved
    }

    // ---------------------------------------------------------------
    // MARK: Clip rect — grSetClipZone
    // ---------------------------------------------------------------

    /// Set the clip rectangle on `layer` (x1,y1)-(x2,y2), with dx/dy.
    /// Translates grSetClipZone() in graphics.c:235–242.
    func setClipZone(
        on layer: inout Framebuffer,
        x1: Int, y1: Int, x2: Int, y2: Int
    ) {
        let cx1 = (x1 + dx).clampedTo(0, Framebuffer.width)
        let cy1 = (y1 + dy).clampedTo(0, Framebuffer.height)
        let cx2 = (x2 + dx).clampedTo(0, Framebuffer.width)
        let cy2 = (y2 + dy).clampedTo(0, Framebuffer.height)
        layer.clipRect = ClipRect(x1: cx1, y1: cy1, x2: cx2, y2: cy2)
    }

    // ---------------------------------------------------------------
    // MARK: Background copy — grCopyZoneToBg
    // ---------------------------------------------------------------

    /// Copy a rectangular region from `layer` to the saved-zones layer.
    /// Translates grCopyZoneToBg() in graphics.c:245–260.
    /// The +2 width padding from the C source (cargo-hull glitch fix) is
    /// reproduced here.
    func copyZoneToBg(
        from layer: Framebuffer,
        x inX: Int, y inY: Int,
        width: Int, height: Int
    ) {
        if savedZonesLayer == nil {
            savedZonesLayer = GraphicsState.newLayer()
        }
        let x1 = inX + dx
        let y1 = inY + dy
        let x2 = min(x1 + width + 2, Framebuffer.width)   // +2 from C source
        let y2 = min(y1 + height, Framebuffer.height)
        for row in y1 ..< y2 {
            guard row >= 0 else { continue }
            for col in x1 ..< x2 {
                guard col >= 0 && col < Framebuffer.width else { continue }
                savedZonesLayer!.pixels[row * Framebuffer.width + col] =
                    layer.pixels[row * Framebuffer.width + col]
            }
        }
    }

    // ---------------------------------------------------------------
    // MARK: SAVE_ZONE / RESTORE_ZONE — grSaveZone / grRestoreZone
    // ---------------------------------------------------------------

    /// Minimalistic SAVE_ZONE: no-op (jc_reborn comment: "we don't
    /// really save the zone, and let RESTORE_ZONE simply erase").
    /// Translates grSaveZone() in graphics.c:272–276.
    func saveZone(x: Int, y: Int, width: Int, height: Int) {
        // no-op
    }

    /// Free the saved-zones layer.
    /// Translates grRestoreZone() in graphics.c:279–285.
    func restoreZone() {
        savedZonesLayer = nil
    }

    // ---------------------------------------------------------------
    // MARK: Background loading
    // ---------------------------------------------------------------

    /// Load a Screen resource as the full background.
    /// Translates grLoadScreen() in graphics.c:505–539. jc_reborn only
    /// allocates `width × height` for the screen surface; rows beyond the
    /// screen height stay at the SDL window's existing (black) pixels. We
    /// emulate that by filling the framebuffer with the 0xFF sentinel so the
    /// shader renders unfilled regions as black, then copying the screen on
    /// top. (Filling with palette index 0 was wrong: it's magenta in Johnny's
    /// palette, producing a magenta band wherever the screen didn't reach.)
    func loadScreen(_ screen: Screen) {
        var fb = Framebuffer(filledWith: 0xFF)
        let count = min(screen.pixels.count, fb.pixels.count)
        for i in 0 ..< count {
            fb.pixels[i] = screen.pixels[i]
        }
        background = fb
        savedZonesLayer = nil
        // A bare loadScreen is, by default, NOT an island background.
        // IslandRenderer.setup() will flip this back to true after it has
        // composited the island/raft/clouds onto the loaded screen.
        isIslandBackground = false
    }

    /// Blit the stored background (from the most recent LOAD_SCREEN) onto a
    /// layer at TTM-space position (x, y). Translates JCOS's DRAW_SCREEN
    /// handler in TTMPlayer.cs:408-419, which does:
    ///   g.DrawImageUnscaled(screenSlot, mc.data[0], mc.data[1])
    /// The dx/dy island offset is applied exactly as for every other draw
    /// primitive. Non-0xFF pixels are copied; 0xFF (sentinel transparent)
    /// pixels are skipped so the layer shows through.
    func drawScreen(on layer: inout Framebuffer, x inX: Int, y inY: Int) {
        guard let bg = background else { return }
        let ox   = inX + dx
        let oy   = inY + dy
        let clip = layer.clipRect
        for row in 0 ..< Framebuffer.height {
            let destRow = oy + row
            guard destRow >= clip.y1 && destRow < clip.y2 else { continue }
            let srcBase = row * Framebuffer.width
            let dstBase = destRow * Framebuffer.width
            for col in 0 ..< Framebuffer.width {
                let destCol = ox + col
                guard destCol >= clip.x1 && destCol < clip.x2 else { continue }
                let px = bg.pixels[srcBase + col]
                if px != 0xFF {
                    layer.pixels[dstBase + destCol] = px
                }
            }
        }
    }

    /// Set an empty background (transparent sentinel; renders as black).
    /// Translates grInitEmptyBackground() in graphics.c:542–554.
    func initEmptyBackground() {
        background = Framebuffer(filledWith: 0xFF)
        savedZonesLayer = nil
        isIslandBackground = false
    }

    // ---------------------------------------------------------------
    // MARK: Composite — translates grUpdateDisplay()
    // ---------------------------------------------------------------

    /// Composite background + savedZones + all active thread layers
    /// into `dest`. Thread layers are passed in draw order (thread 0
    /// first). The holiday layer (Phase 3) comes last.
    func composite(
        threadLayers: [Framebuffer],
        into dest: inout Framebuffer
    ) {
        // 1. Background — fall back to the 0xFF sentinel (renders as black
        // via the shader). Filling with 0 was wrong: that's the magenta
        // colour-key index in Johnny's palette, producing a magenta box
        // around scenes played without an island background (e.g. the debug
        // overlay's "Play" button).
        if let bg = background {
            dest = bg
        } else {
            dest.clearAll(to: 0xFF)
        }
        // 2. Saved-zones layer
        if let sz = savedZonesLayer {
            dest.composite(layer: sz)
        }
        // 3. Thread layers in order
        for layer in threadLayers {
            dest.composite(layer: layer)
        }
    }

    // ---------------------------------------------------------------
    // MARK: Private helpers
    // ---------------------------------------------------------------

    private func drawHLine(
        on layer: inout Framebuffer,
        x1: Int, x2: Int, y: Int,
        color: UInt8
    ) {
        let clip = layer.clipRect
        guard y >= clip.y1 && y < clip.y2 else { return }
        let cx1 = max(x1, clip.x1)
        let cx2 = min(x2, clip.x2)
        guard cx1 < cx2 else { return }
        let base = y * Framebuffer.width
        for x in cx1 ..< cx2 {
            layer.pixels[base + x] = color
        }
    }
}

// MARK: - Clamping helpers (engine-internal)

extension Int {
    /// Clamp to a closed range. Used by Graphics primitives.
    @inline(__always)
    func clampedTo(_ lo: Int, _ hi: Int) -> Int {
        Swift.max(lo, Swift.min(hi, self))
    }
}
