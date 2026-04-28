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
        let x1 = (inX + dx).clampedTo(0, Framebuffer.width - 1)
        let y1 = (inY + dy).clampedTo(0, Framebuffer.height - 1)
        let x2 = (inX + dx + width).clampedTo(0, Framebuffer.width)
        let y2 = (inY + dy + height).clampedTo(0, Framebuffer.height)
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
    func drawSprite(
        on layer: inout Framebuffer,
        bitmap: Bitmap,
        x inX: Int, y inY: Int,
        spriteNo: Int, imageNo: Int
    ) {
        guard imageNo < bitmap.imageCount, spriteNo < bitmap.imageCount else { return }
        let bx = inX + dx
        let by = inY + dy
        let w  = Int(bitmap.widths[spriteNo])
        let h  = Int(bitmap.heights[spriteNo])
        let spritePixels = bitmap.pixels(forSprite: spriteNo)
        for row in 0 ..< h {
            let dy2 = by + row
            guard dy2 >= 0 && dy2 < Framebuffer.height else { continue }
            for col in 0 ..< w {
                let dx2 = bx + col
                guard dx2 >= 0 && dx2 < Framebuffer.width else { continue }
                let px = spritePixels[row * w + col]
                if px != 0xFF {
                    layer.pixels[dy2 * Framebuffer.width + dx2] = px
                }
            }
        }
    }

    /// Blit sprite horizontally flipped at (x, y).
    /// Translates grDrawSpriteFlip() in graphics.c:472–491.
    func drawSpriteFlip(
        on layer: inout Framebuffer,
        bitmap: Bitmap,
        x inX: Int, y inY: Int,
        spriteNo: Int, imageNo: Int
    ) {
        guard imageNo < bitmap.imageCount, spriteNo < bitmap.imageCount else { return }
        let w  = Int(bitmap.widths[spriteNo])
        let h  = Int(bitmap.heights[spriteNo])
        // flip: x coordinate starts at right edge (x + w - 1), column 0 lands there
        let bx = (inX + dx) + (w - 1)
        let by = inY + dy
        let spritePixels = bitmap.pixels(forSprite: spriteNo)
        for row in 0 ..< h {
            let dy2 = by + row
            guard dy2 >= 0 && dy2 < Framebuffer.height else { continue }
            for col in 0 ..< w {
                let dx2 = bx - col    // mirror x
                guard dx2 >= 0 && dx2 < Framebuffer.width else { continue }
                let px = spritePixels[row * w + col]
                if px != 0xFF {
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
    /// Translates grClearScreen() in graphics.c:494–502.
    func clearScreen(layer: inout Framebuffer) {
        let saved = layer.clipRect
        layer.clearClipped(to: 0xFF)  // clear only the clipped area
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
    /// Translates grLoadScreen() in graphics.c:505–539.
    /// The Screen is already in 8bpp indexed format (Phase 1 unpacked).
    func loadScreen(_ screen: Screen) {
        var fb = Framebuffer(filledWith: 0)
        let count = min(screen.pixels.count, fb.pixels.count)
        for i in 0 ..< count {
            fb.pixels[i] = screen.pixels[i]
        }
        background = fb
        savedZonesLayer = nil
    }

    /// Set an empty (zeroed) background.
    /// Translates grInitEmptyBackground() in graphics.c:542–554.
    func initEmptyBackground() {
        background = Framebuffer(filledWith: 0)
        savedZonesLayer = nil
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
        // 1. Background
        if let bg = background {
            dest = bg
        } else {
            dest.clearAll(to: 0)
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
        guard y >= 0 && y < Framebuffer.height else { return }
        let cx1 = max(x1, 0)
        let cx2 = min(x2, Framebuffer.width)
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
