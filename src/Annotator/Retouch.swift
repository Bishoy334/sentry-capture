import AppKit

/// Phase E retouch, hand-rolled (research §4: macOS ships no public
/// inpainting API — this is the honest version). Heal fills a rect by
/// interpolating the border pixels inward — exact for the flat and gradient
/// backgrounds that dominate screenshots, smeary on texture (that's the
/// documented ceiling). Clone copies pixels from an offset source through a
/// soft round brush.
enum Retouch {
    // MARK: Heal

    /// New base with `holePx` (pixel coords, top-left origin) refilled from
    /// its border. Each hole pixel is the inverse-distance blend of the four
    /// axis-aligned border pixels; sides beyond the image edge drop out.
    static func healed(base: CGImage, holePx: CGRect) -> CGImage? {
        let imgW = base.width
        let imgH = base.height
        let hole = holePx.integral.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard hole.width >= 1, hole.height >= 1,
              hole.width < CGFloat(imgW) || hole.height < CGFloat(imgH) else { return nil }
        let x0 = Int(hole.minX), y0 = Int(hole.minY)
        let w = Int(hole.width), h = Int(hole.height)

        // Read the hole grown by 1px — the border ring feeds the fill.
        let grown = hole.insetBy(dx: -1, dy: -1)
            .intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        let gx = Int(grown.minX), gy = Int(grown.minY)
        let gw = Int(grown.width), gh = Int(grown.height)
        guard let region = base.cropping(to: grown) else { return nil }
        var px = [UInt8](repeating: 0, count: gw * gh * 4)
        guard let readCtx = CGContext(
            data: &px, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        readCtx.draw(region, in: CGRect(x: 0, y: 0, width: gw, height: gh))

        // Border availability: a hole flush with the image edge loses that side.
        let hasLeft = x0 > gx
        let hasRight = gx + gw > x0 + w
        let hasTop = y0 > gy
        let hasBottom = gy + gh > y0 + h
        guard hasLeft || hasRight || hasTop || hasBottom else { return nil }

        var patch = [UInt8](repeating: 255, count: w * h * 4)
        func sample(_ bx: Int, _ by: Int) -> (Double, Double, Double) {
            let i = (by * gw + bx) * 4
            return (Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
        }
        for y in 0..<h {
            let by = y + (y0 - gy)
            for x in 0..<w {
                let bx = x + (x0 - gx)
                var r = 0.0, g = 0.0, b = 0.0, wsum = 0.0
                func add(_ c: (Double, Double, Double), _ dist: Int) {
                    let weight = 1.0 / Double(max(dist, 1))
                    r += c.0 * weight
                    g += c.1 * weight
                    b += c.2 * weight
                    wsum += weight
                }
                if hasLeft { add(sample(x0 - gx - 1, by), x + 1) }
                if hasRight { add(sample(x0 - gx + w, by), w - x) }
                if hasTop { add(sample(bx, y0 - gy - 1), y + 1) }
                if hasBottom { add(sample(bx, y0 - gy + h), h - y) }
                let i = (y * w + x) * 4
                patch[i] = UInt8(min(max(r / wsum, 0), 255))
                patch[i + 1] = UInt8(min(max(g / wsum, 0), 255))
                patch[i + 2] = UInt8(min(max(b / wsum, 0), 255))
            }
        }
        let patchImage: CGImage? = patch.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        guard let patchImage,
              let out = CGContext(
                  data: nil, width: imgW, height: imgH,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        out.draw(base, in: CGRect(x: 0, y: 0, width: imgW, height: imgH))
        // Pixel top-left -> CG bottom-left.
        out.draw(patchImage, in: CGRect(
            x: x0, y: imgH - y0 - h, width: w, height: h))
        return out.makeImage()
    }

    // MARK: Clone stamp

    /// Soft round brush alpha (white core fading to black edge) — clip mask
    /// for stamps. Built once; rotationally symmetric so flips don't matter.
    static let brushMask: CGImage? = {
        let side = 128
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1),
                     CGColor(gray: 0, alpha: 1)] as CFArray,
            locations: [0, 0.62, 1]) else { return nil }
        let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        ctx.drawRadialGradient(
            gradient, startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: CGFloat(side) / 2, options: [])
        return ctx.makeImage()
    }()

    /// Draw clone stamps into a context whose CTM maps TOP-LEFT image point
    /// coordinates (the canvas draw context and the bake context both do).
    /// Each stamp copies `source` pixels from the offset position through
    /// the soft brush. Stamps whose source falls off the image are skipped.
    static func drawStamps(
        _ stamps: [CGPoint], brush: CGFloat, offset: CGPoint,
        source: CGImage, scale: CGFloat,
        in ctx: CGContext, canvasHeight: CGFloat
    ) {
        guard let mask = brushMask else { return }
        let sourceBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        for p in stamps {
            let dest = CGRect(
                x: p.x - brush / 2, y: p.y - brush / 2, width: brush, height: brush)
            let sourcePx = CGRect(
                x: (dest.minX + offset.x) * scale, y: (dest.minY + offset.y) * scale,
                width: brush * scale, height: brush * scale)
            guard sourceBounds.contains(sourcePx),
                  let crop = source.cropping(to: sourcePx) else { continue }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: canvasHeight)
            ctx.scaleBy(x: 1, y: -1)
            let flipped = CGRect(
                x: dest.minX, y: canvasHeight - dest.maxY,
                width: dest.width, height: dest.height)
            ctx.clip(to: flipped, mask: mask)
            ctx.draw(crop, in: flipped)
            ctx.restoreGState()
        }
    }

    /// Bake a finished stroke: current base + all stamps -> new base.
    static func stamped(
        base: CGImage, stamps: [CGPoint], brush: CGFloat,
        offset: CGPoint, source: CGImage, scale: CGFloat
    ) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: base.width, height: base.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let pointHeight = CGFloat(base.height) / scale
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: pointHeight)
        ctx.scaleBy(x: 1, y: -1)   // now top-left point coords, as drawStamps expects
        drawStamps(
            stamps, brush: brush, offset: offset, source: source, scale: scale,
            in: ctx, canvasHeight: pointHeight)
        return ctx.makeImage()
    }
}
