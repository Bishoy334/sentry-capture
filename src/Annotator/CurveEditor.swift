import AppKit

// MARK: - Spline math

enum CurveMath {
    /// Monotone cubic interpolation (Fritsch–Carlson) through sorted control
    /// points — no overshoot between points, output clamped to 0…1. Chosen
    /// over Catmull-Rom because a tone curve that oscillates past its control
    /// points produces banding surprises.
    static func value(at x: CGFloat, points: [CGPoint]) -> CGFloat {
        let pts = points.sorted { $0.x < $1.x }
        guard pts.count >= 2 else { return min(max(x, 0), 1) }
        guard let first = pts.first, let last = pts.last else { return x }
        if x <= first.x { return min(max(first.y, 0), 1) }
        if x >= last.x { return min(max(last.y, 0), 1) }

        let n = pts.count
        var secants = [CGFloat]()
        for i in 0..<(n - 1) {
            let dx = max(pts[i + 1].x - pts[i].x, 0.0001)
            secants.append((pts[i + 1].y - pts[i].y) / dx)
        }
        var slopes = [CGFloat](repeating: 0, count: n)
        slopes[0] = secants[0]
        slopes[n - 1] = secants[n - 2]
        for i in 1..<(n - 1) {
            slopes[i] = secants[i - 1] * secants[i] <= 0 ? 0 : (secants[i - 1] + secants[i]) / 2
        }
        for i in 0..<(n - 1) {
            if secants[i] == 0 {
                slopes[i] = 0
                slopes[i + 1] = 0
                continue
            }
            let a = slopes[i] / secants[i]
            let b = slopes[i + 1] / secants[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                slopes[i] = t * a * secants[i]
                slopes[i + 1] = t * b * secants[i]
            }
        }

        var i = 0
        while i < n - 2 && x > pts[i + 1].x { i += 1 }
        let h = max(pts[i + 1].x - pts[i].x, 0.0001)
        let t = (x - pts[i].x) / h
        let t2 = t * t
        let t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * pts[i].y
            + (t3 - 2 * t2 + t) * h * slopes[i]
            + (-2 * t3 + 3 * t2) * pts[i + 1].y
            + (t3 - t2) * h * slopes[i + 1]
        return min(max(y, 0), 1)
    }

    /// Luminance histogram (normalised so the tallest bin = 1) from an
    /// already-downsampled image — backdrop for the curve widget.
    static func histogram(of image: CGImage, bins: Int = 64) -> [CGFloat] {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0, bins > 0 else { return [] }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var counts = [CGFloat](repeating: 0, count: bins)
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 128 {
            let luma = 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
            counts[min(Int(luma / 255 * Double(bins)), bins - 1)] += 1
        }
        let peak = counts.max() ?? 1
        return peak > 0 ? counts.map { $0 / peak } : counts
    }
}

// MARK: - Widget

/// The curves control (plan Phase D: "the one custom control worth real
/// effort"): histogram behind, monotone spline through draggable points.
/// Click the line to add a point, drag to shape, double-click a point to
/// remove it. Endpoints slide vertically only — that's the levels control.
final class CurveEditorView: NSView {
    /// Normalised control points (y-up). Always sorted, endpoints at x 0/1.
    var points: [CGPoint] = ImageAdjustments.identityCurve {
        didSet { if points != oldValue { needsDisplay = true } }
    }
    var histogram: [CGFloat] = [] {
        didSet { needsDisplay = true }
    }
    /// Fires on every drag tick — live preview; the canvas throttles renders.
    var onChange: (([CGPoint]) -> Void)?

    private var dragIndex: Int?
    private let inset: CGFloat = 7

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var plot: CGRect { bounds.insetBy(dx: inset, dy: inset) }

    private func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: plot.minX + p.x * plot.width, y: plot.minY + p.y * plot.height)
    }

    private func normalPoint(_ v: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max((v.x - plot.minX) / plot.width, 0), 1),
            y: min(max((v.y - plot.minY) / plot.height, 0), 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.04).cgColor)
        let bg = CGPath(roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(bg)
        ctx.fillPath()

        if !histogram.isEmpty {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
            let barW = plot.width / CGFloat(histogram.count)
            for (i, v) in histogram.enumerated() where v > 0 {
                ctx.fill(CGRect(
                    x: plot.minX + CGFloat(i) * barW, y: plot.minY,
                    width: barW, height: v * plot.height))
            }
        }

        // Thirds grid + diagonal reference.
        ctx.setStrokeColor(HUDStyle.hairline.cgColor)
        ctx.setLineWidth(1)
        for f in [1.0 / 3.0, 2.0 / 3.0] {
            ctx.move(to: CGPoint(x: plot.minX + plot.width * f, y: plot.minY))
            ctx.addLine(to: CGPoint(x: plot.minX + plot.width * f, y: plot.maxY))
            ctx.move(to: CGPoint(x: plot.minX, y: plot.minY + plot.height * f))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.minY + plot.height * f))
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.move(to: viewPoint(.zero))
        ctx.addLine(to: viewPoint(CGPoint(x: 1, y: 1)))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // The curve.
        ctx.setStrokeColor(HUDStyle.accent.cgColor)
        ctx.setLineWidth(1.5)
        let steps = 64
        ctx.move(to: viewPoint(CGPoint(x: 0, y: CurveMath.value(at: 0, points: points))))
        for i in 1...steps {
            let x = CGFloat(i) / CGFloat(steps)
            ctx.addLine(to: viewPoint(CGPoint(x: x, y: CurveMath.value(at: x, points: points))))
        }
        ctx.strokePath()

        for p in points {
            let v = viewPoint(p)
            let r = CGRect(x: v.x - 3.5, y: v.y - 3.5, width: 7, height: 7)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setStrokeColor(HUDStyle.accent.cgColor)
            ctx.fillEllipse(in: r)
            ctx.strokeEllipse(in: r)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if let hit = points.firstIndex(where: {
            let p = viewPoint($0)
            return abs(p.x - v.x) <= 8 && abs(p.y - v.y) <= 8
        }) {
            if event.clickCount == 2, hit != 0, hit != points.count - 1 {
                points.remove(at: hit)
                dragIndex = nil
                onChange?(points)
                return
            }
            dragIndex = hit
            return
        }
        // Add a point where clicked (snapped onto the current curve height
        // feels magnetic; use the raw click so pulling away is one gesture).
        let n = normalPoint(v)
        let index = points.firstIndex { $0.x > n.x } ?? points.count - 1
        points.insert(n, at: max(min(index, points.count - 1), 1))
        dragIndex = points.firstIndex(of: n)
        onChange?(points)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let i = dragIndex else { return }
        var n = normalPoint(convert(event.locationInWindow, from: nil))
        if i == 0 {
            n.x = 0            // endpoints move vertically only (levels)
        } else if i == points.count - 1 {
            n.x = 1
        } else {
            // Interior points stay strictly between their neighbours.
            n.x = min(max(n.x, points[i - 1].x + 0.02), points[i + 1].x - 0.02)
        }
        points[i] = n
        onChange?(points)
    }

    override func mouseUp(with event: NSEvent) {
        dragIndex = nil
        onChange?(points)
    }
}
