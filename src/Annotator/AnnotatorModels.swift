import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Tools

enum AnnotatorTool: CaseIterable {
    case select, crop, lift, arrow, line, rect, filledRect, ellipse, draw, highlighter, text, counter, redact, spotlight, magnifier, heal, clone

    var key: String {
        switch self {
        case .select: return "v"
        case .crop: return "k"
        case .lift: return "w"
        case .magnifier: return "g"
        case .heal: return "j"
        case .clone: return "n"
        case .arrow: return "a"
        case .line: return "l"
        case .rect: return "r"
        case .filledRect: return "f"
        case .ellipse: return "e"
        case .draw: return "d"
        case .highlighter: return "m"
        case .text: return "t"
        case .counter: return "c"
        case .redact: return "p"
        case .spotlight: return "h"
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .lift: return "wand.and.stars"
        case .magnifier: return "plus.magnifyingglass"
        case .heal: return "bandage"
        case .clone: return "square.on.square.dashed"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .filledRect: return "rectangle.fill"
        case .ellipse: return "oval"
        case .draw: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "number.circle"
        case .redact: return "checkerboard.rectangle"
        case .spotlight: return "rays"
        }
    }

    var label: String {
        switch self {
        case .select: return "Select"
        case .crop: return "Crop"
        case .lift: return "Lift Subject"
        case .magnifier: return "Magnify"
        case .heal: return "Heal"
        case .clone: return "Clone Stamp"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Rectangle"
        case .filledRect: return "Filled Rectangle"
        case .ellipse: return "Ellipse"
        case .draw: return "Draw"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .counter: return "Counter"
        case .redact: return "Redact"
        case .spotlight: return "Spotlight"
        }
    }
}

enum AnnotatorRedactStyle: Int, Equatable, Codable {
    case pixelate, blur, secure, blackout
}

enum AnnotatorArrowStyle: Int, Equatable, Codable, CaseIterable {
    case straight, curved, double, dashed

    var label: String {
        switch self {
        case .straight: return "Straight"
        case .curved: return "Curved"
        case .double: return "Double"
        case .dashed: return "Dashed"
        }
    }
}

enum AnnotatorTextStyle: Int, Equatable, Codable, CaseIterable {
    case standard, rounded, mono, outlined, boxed, roundBoxed, monoBoxed, bubble

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .rounded: return "Rounded"
        case .mono: return "Monospaced"
        case .outlined: return "Outlined"
        case .boxed: return "Boxed"
        case .roundBoxed: return "Round Boxed"
        case .monoBoxed: return "Mono Boxed"
        case .bubble: return "Speech Bubble"
        }
    }

    var isBoxed: Bool {
        self == .boxed || self == .roundBoxed || self == .monoBoxed
    }

    func font(size: CGFloat) -> NSFont {
        switch self {
        case .mono, .monoBoxed:
            return .monospacedSystemFont(ofSize: size, weight: .semibold)
        case .rounded:
            let base = NSFont.systemFont(ofSize: size, weight: .semibold)
            if let descriptor = base.fontDescriptor.withDesign(.rounded),
               let rounded = NSFont(descriptor: descriptor, size: size) {
                return rounded
            }
            return base
        default:
            return .systemFont(ofSize: size, weight: .semibold)
        }
    }
}

/// Whole-canvas orientation ops (toolbar Rotate & Flip menu).
enum AnnotatorBaseTransform {
    case rotateLeft, rotateRight, flipHorizontal, flipVertical

    var orientation: CGImagePropertyOrientation {
        switch self {
        case .rotateRight: return .right
        case .rotateLeft: return .left
        case .flipHorizontal: return .upMirrored
        case .flipVertical: return .downMirrored
        }
    }

    var undoName: String {
        switch self {
        case .rotateRight: return "Rotate Right"
        case .rotateLeft: return "Rotate Left"
        case .flipHorizontal: return "Flip Horizontal"
        case .flipVertical: return "Flip Vertical"
        }
    }
}

enum AnnotatorKind: String, Equatable, Codable {
    case arrow, line, rect, filledRect, ellipse, freehand, highlighter, text, counter, redact, spotlight, image, sticker, magnifier
}

/// Dropped-in images ride annotations as a reference type so the flat value
/// struct stays cheaply copyable (undo snapshots share the bitmap).
final class AnnotatorImageRef: Equatable {
    let image: CGImage
    init(image: CGImage) { self.image = image }
    static func == (lhs: AnnotatorImageRef, rhs: AnnotatorImageRef) -> Bool { lhs === rhs }
}

/// The "make it pretty" wrapper: padded, rounded, shadowed capture on a
/// solid/gradient backdrop. Non-destructive — applied at export, previewed
/// live by the backdrop view.
struct AnnotatorBackgroundStyle: Equatable {
    enum Fill: Equatable {
        case none
        case solid(NSColor)
        case gradient(Int)
    }

    var fill: Fill = .none
    var padding: CGFloat = 48
    var cornerRadius: CGFloat = 12
    var shadow: Bool = true

    var isVisible: Bool { fill != .none }

    static let gradientPresets: [(name: String, colours: [NSColor])] = [
        ("Dusk", [NSColor(srgbRed: 0.35, green: 0.22, blue: 0.58, alpha: 1),
                  NSColor(srgbRed: 0.86, green: 0.34, blue: 0.44, alpha: 1)]),
        ("Ocean", [NSColor(srgbRed: 0.10, green: 0.35, blue: 0.62, alpha: 1),
                   NSColor(srgbRed: 0.22, green: 0.74, blue: 0.76, alpha: 1)]),
        ("Meadow", [NSColor(srgbRed: 0.13, green: 0.48, blue: 0.35, alpha: 1),
                    NSColor(srgbRed: 0.72, green: 0.86, blue: 0.42, alpha: 1)]),
        ("Ember", [NSColor(srgbRed: 0.85, green: 0.42, blue: 0.16, alpha: 1),
                   NSColor(srgbRed: 0.96, green: 0.76, blue: 0.32, alpha: 1)]),
        ("Slate", [NSColor(srgbRed: 0.16, green: 0.18, blue: 0.24, alpha: 1),
                   NSColor(srgbRed: 0.42, green: 0.46, blue: 0.56, alpha: 1)]),
    ]

    static let solidPresets: [(name: String, colour: NSColor)] = [
        ("White", .white),
        ("Charcoal", NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)),
    ]

    /// Draw the fill into a rect — shared by the live backdrop preview and
    /// the export compositor.
    func drawFill(in rect: CGRect, ctx: CGContext) {
        switch fill {
        case .none:
            break
        case .solid(let colour):
            ctx.setFillColor(colour.cgColor)
            ctx.fill(rect)
        case .gradient(let index):
            let preset = Self.gradientPresets[
                min(max(index, 0), Self.gradientPresets.count - 1)]
            let colours = preset.colours.map(\.cgColor) as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: colours, locations: [0, 1]) else { return }
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }
}

/// One annotation, in IMAGE POINT coordinates (top-left origin). Which fields
/// are meaningful depends on `kind`; one flat value type keeps undo snapshots
/// and Equatable comparison free.
struct AnnotatorAnnotation: Identifiable, Equatable {
    var id = UUID()
    var kind: AnnotatorKind
    var rect: CGRect = .zero            // rect-like kinds + text + counter + spotlight
    var start: CGPoint = .zero          // line / arrow endpoints
    var end: CGPoint = .zero
    var points: [CGPoint] = []          // freehand / highlighter
    var colour: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var text: NSAttributedString?
    var textSize: CGFloat = 20
    var textStyle: AnnotatorTextStyle = .standard
    var number: Int = 0                 // counter badge
    var redactStyle: AnnotatorRedactStyle = .pixelate
    var arrowStyle: AnnotatorArrowStyle = .straight
    var imageRef: AnnotatorImageRef?   // .image kind
    /// Watermark plumbing (text/image objects): translucency and repeat.
    var opacity: CGFloat = 1
    var tiled: Bool = false
}

// MARK: - Geometry

enum AnnotatorGeo {
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Core geometry bounds, before stroke width or selection chrome.
    static func bounds(of a: AnnotatorAnnotation) -> CGRect {
        switch a.kind {
        case .line, .arrow:
            return rect(from: a.start, to: a.end)
        case .freehand, .highlighter:
            guard let first = a.points.first else { return .zero }
            var r = CGRect(origin: first, size: .zero)
            for p in a.points.dropFirst() {
                r = r.union(CGRect(origin: p, size: .zero))
            }
            return r
        default:
            return a.rect
        }
    }

    /// Bounds inflated to cover stroke, arrow head and selection chrome —
    /// what setNeedsDisplay must invalidate. Generous rather than exact so a
    /// zoomed-out canvas (chrome drawn at 1/zoom scale) is still covered.
    static func displayBounds(of a: AnnotatorAnnotation) -> CGRect {
        let slop = a.lineWidth * 4 + 40
        return bounds(of: a).insetBy(dx: -slop, dy: -slop)
    }

    /// Decimate near-duplicate samples, then a light moving average —
    /// enough to iron out mouse jitter without rounding intentional corners.
    static func smoothed(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 4 else { return points }
        var out: [CGPoint] = [points[0]]
        for p in points.dropFirst() where hypot(p.x - out[out.count - 1].x, p.y - out[out.count - 1].y) >= 2 {
            out.append(p)
        }
        if let last = points.last, out.last != last { out.append(last) }
        guard out.count > 4 else { return out }
        var smooth = out
        for i in 1..<(out.count - 1) {
            smooth[i] = CGPoint(
                x: (out[i - 1].x + out[i].x + out[i + 1].x) / 3,
                y: (out[i - 1].y + out[i].y + out[i + 1].y) / 3)
        }
        return smooth
    }

    /// A mostly-flat stroke wide enough to be underlining text collapses to a
    /// straight band at the stroke's mean height; nil = keep as drawn.
    static func horizontalBand(_ points: [CGPoint]) -> [CGPoint]? {
        guard let first = points.first, let last = points.last, points.count > 2 else { return nil }
        let ys = points.map(\.y)
        guard let minY = ys.min(), let maxY = ys.max() else { return nil }
        let width = abs(last.x - first.x)
        guard width > 24, (maxY - minY) < max(14, width * 0.15) else { return nil }
        let mean = ys.reduce(0, +) / CGFloat(ys.count)
        return [CGPoint(x: first.x, y: mean), CGPoint(x: last.x, y: mean)]
    }

    /// The canvas is the base image grown to cover every annotation (plus a
    /// stroke margin) — the one rule both the live canvas and the exporter
    /// use, so what you see beyond the edge is what exports.
    static func canvasBounds(imageSize: NSSize, annotations: [AnnotatorAnnotation]) -> CGRect {
        var bounds = CGRect(origin: .zero, size: imageSize)
        for a in annotations {
            let b = self.bounds(of: a).insetBy(dx: -a.lineWidth - 6, dy: -a.lineWidth - 6)
            guard !b.isNull, !b.isEmpty else { continue }
            bounds = bounds.union(b)
        }
        return bounds.integral
    }

    /// Point remap for whole-canvas rotate/flip, in top-left image points.
    static func transform(
        _ p: CGPoint, by t: AnnotatorBaseTransform, in size: NSSize
    ) -> CGPoint {
        switch t {
        case .rotateRight: return CGPoint(x: size.height - p.y, y: p.x)
        case .rotateLeft: return CGPoint(x: p.y, y: size.width - p.x)
        case .flipHorizontal: return CGPoint(x: size.width - p.x, y: p.y)
        case .flipVertical: return CGPoint(x: p.x, y: size.height - p.y)
        }
    }

    /// Remap an annotation's geometry for a base rotate/flip. Glyph-bearing
    /// kinds (text/counter/sticker) keep their box size and move by centre —
    /// glyphs stay horizontal regardless of image orientation.
    static func transform(
        _ a: AnnotatorAnnotation, by t: AnnotatorBaseTransform, in size: NSSize
    ) -> AnnotatorAnnotation {
        var out = a
        out.start = transform(a.start, by: t, in: size)
        out.end = transform(a.end, by: t, in: size)
        out.points = a.points.map { transform($0, by: t, in: size) }
        let c1 = transform(CGPoint(x: a.rect.minX, y: a.rect.minY), by: t, in: size)
        let c2 = transform(CGPoint(x: a.rect.maxX, y: a.rect.maxY), by: t, in: size)
        var mapped = rect(from: c1, to: c2)
        switch a.kind {
        case .text, .counter, .sticker:
            mapped = CGRect(
                x: mapped.midX - a.rect.width / 2, y: mapped.midY - a.rect.height / 2,
                width: a.rect.width, height: a.rect.height)
        default:
            break
        }
        out.rect = mapped
        return out
    }

    static func translate(_ a: AnnotatorAnnotation, by d: CGPoint) -> AnnotatorAnnotation {
        var t = a
        t.rect.origin.x += d.x
        t.rect.origin.y += d.y
        t.start.x += d.x
        t.start.y += d.y
        t.end.x += d.x
        t.end.y += d.y
        t.points = t.points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        return t
    }
}

// MARK: - Paths

enum AnnotatorPaths {
    static func freehand(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count < 3 {
            for p in points.dropFirst() { path.addLine(to: p) }
            return path
        }
        // Quadratic curves through segment midpoints — cheap auto-smoothing.
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func segment(_ a: CGPoint, _ b: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    /// The hit-testable outline of a stroked annotation. Filled kinds
    /// hit-test by containment and don't come through here.
    static func outline(_ a: AnnotatorAnnotation) -> CGPath? {
        switch a.kind {
        case .line, .arrow: return segment(a.start, a.end)
        case .freehand, .highlighter: return freehand(a.points)
        case .rect: return CGPath(rect: a.rect, transform: nil)
        case .ellipse: return CGPath(ellipseIn: a.rect, transform: nil)
        default: return nil
        }
    }
}

// MARK: - Hit testing

enum AnnotatorHandle: Equatable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case lineStart, lineEnd
}

enum AnnotatorHit {
    static func fatContains(_ path: CGPath, width: CGFloat, point: CGPoint) -> Bool {
        path.copy(strokingWithWidth: max(width, 12), lineCap: .round, lineJoin: .round, miterLimit: 10)
            .contains(point)
    }

    static func hitTest(_ a: AnnotatorAnnotation, at p: CGPoint) -> Bool {
        switch a.kind {
        case .line, .arrow, .freehand, .rect, .ellipse:
            guard let path = AnnotatorPaths.outline(a) else { return false }
            return fatContains(path, width: a.lineWidth, point: p)
        case .highlighter:
            guard let path = AnnotatorPaths.outline(a) else { return false }
            return fatContains(path, width: AnnotatorRender.highlighterWidth, point: p)
        case .filledRect, .redact, .spotlight, .image, .sticker, .magnifier:
            return a.rect.insetBy(dx: -4, dy: -4).contains(p)
        case .text:
            return a.rect.insetBy(dx: -6, dy: -6).contains(p)
        case .counter:
            let c = CGPoint(x: a.rect.midX, y: a.rect.midY)
            return hypot(p.x - c.x, p.y - c.y) <= a.rect.width / 2 + 4
        }
    }

    static func rectHandles(_ r: CGRect) -> [(AnnotatorHandle, CGPoint)] {
        [
            (.topLeft, CGPoint(x: r.minX, y: r.minY)),
            (.top, CGPoint(x: r.midX, y: r.minY)),
            (.topRight, CGPoint(x: r.maxX, y: r.minY)),
            (.right, CGPoint(x: r.maxX, y: r.midY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)),
            (.bottom, CGPoint(x: r.midX, y: r.maxY)),
            (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
            (.left, CGPoint(x: r.minX, y: r.midY)),
        ]
    }

    static func handles(for a: AnnotatorAnnotation) -> [(AnnotatorHandle, CGPoint)] {
        switch a.kind {
        case .line, .arrow:
            return [(.lineStart, a.start), (.lineEnd, a.end)]
        case .rect, .filledRect, .ellipse, .redact, .text, .spotlight, .image, .sticker:
            return rectHandles(a.rect)
        case .magnifier:
            // Corner handles size the loupe; the extra handle is the source
            // anchor (what gets magnified).
            return rectHandles(a.rect) + [(.lineStart, a.start)]
        case .freehand, .highlighter, .counter:
            return []   // move-only
        }
    }

    static func handleHit(
        _ handles: [(AnnotatorHandle, CGPoint)], at p: CGPoint, slop: CGFloat
    ) -> AnnotatorHandle? {
        handles.first { abs($0.1.x - p.x) <= slop && abs($0.1.y - p.y) <= slop }?.0
    }

    /// Resize keeping the opposite edge(s) fixed; the result is normalised,
    /// so dragging past the far edge flips the rect rather than going negative.
    static func resize(_ r: CGRect, handle: AnnotatorHandle, to p: CGPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        case .lineStart, .lineEnd: return r
        }
        return CGRect(
            x: min(minX, maxX), y: min(minY, maxY),
            width: abs(maxX - minX), height: abs(maxY - minY)
        )
    }
}

// MARK: - Shared draw routine

enum AnnotatorRender {
    static let highlighterWidth: CGFloat = 18
    static let counterDiameter: CGFloat = 24

    static func textAttributes(
        size: CGFloat, colour: NSColor, style: AnnotatorTextStyle = .standard
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.font(size: size),
        ]
        switch style {
        case .outlined:
            // Negative stroke width = stroke AND fill; the contrasting outline
            // keeps text legible on any background.
            attributes[.foregroundColor] = colour
            attributes[.strokeColor] = contrastColour(on: colour)
            attributes[.strokeWidth] = -3.5
        case .boxed, .roundBoxed, .monoBoxed:
            // The box carries the colour; the glyphs contrast against it.
            attributes[.foregroundColor] = contrastColour(on: colour)
        default:
            attributes[.foregroundColor] = colour
        }
        return attributes
    }

    static func attributed(
        _ string: String, size: CGFloat, colour: NSColor, style: AnnotatorTextStyle = .standard
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: textAttributes(size: size, colour: colour, style: style))
    }

    static func contrastColour(on colour: NSColor) -> NSColor {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.7 ? .black : .white
    }

    /// Blit a CGImage into a flipped (top-left origin) context without it
    /// rendering upside down.
    static func blitFlipped(_ image: CGImage, in rect: CGRect, ctx: CGContext, canvasHeight: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: canvasHeight)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(
            x: rect.minX, y: canvasHeight - rect.maxY, width: rect.width, height: rect.height
        ))
        ctx.restoreGState()
    }

    /// The one draw routine both the canvas and the exporter use — WYSIWYG by
    /// construction. The context CTM must map top-left image points, and an
    /// NSGraphicsContext must be current (text drawing needs it).
    static func draw(
        _ a: AnnotatorAnnotation,
        in ctx: CGContext,
        canvasHeight: CGFloat,
        redactPatch: (rect: CGRect, image: CGImage)?
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if a.opacity < 1 {
            ctx.setAlpha(a.opacity)   // watermarks; 1 = the untouched default
        }
        switch a.kind {
        case .line:
            ctx.setStrokeColor(a.colour.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineCap(.round)
            ctx.addPath(AnnotatorPaths.segment(a.start, a.end))
            ctx.strokePath()
        case .arrow:
            drawArrow(a, in: ctx)
        case .rect:
            ctx.setStrokeColor(a.colour.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.stroke(a.rect)
        case .filledRect:
            ctx.setFillColor(a.colour.cgColor)
            ctx.fill(a.rect)
        case .ellipse:
            ctx.setStrokeColor(a.colour.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.strokeEllipse(in: a.rect)
        case .freehand:
            ctx.setStrokeColor(a.colour.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(AnnotatorPaths.freehand(a.points))
            ctx.strokePath()
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(a.colour.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(highlighterWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(AnnotatorPaths.freehand(a.points))
            ctx.strokePath()
        case .text:
            if a.textStyle.isBoxed {
                let radius: CGFloat = a.textStyle == .roundBoxed
                    ? min(a.rect.height / 2 + 3, 14)
                    : 4
                let box = a.rect.insetBy(dx: -7, dy: -4)
                ctx.setFillColor(a.colour.cgColor)
                ctx.addPath(CGPath(
                    roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            }
            if a.textStyle == .bubble {
                // White bubble + tail, bordered in the annotation colour; the
                // union keeps the tail seam out of the stroke.
                let box = a.rect.insetBy(dx: -10, dy: -8)
                let body = CGPath(
                    roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil)
                let tail = CGMutablePath()
                tail.move(to: CGPoint(x: box.minX + 12, y: box.maxY - 4))
                tail.addLine(to: CGPoint(x: box.minX + 32, y: box.maxY - 4))
                tail.addLine(to: CGPoint(x: box.minX + 4, y: box.maxY + 18))
                tail.closeSubpath()
                let bubble = body.union(tail)
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.97).cgColor)
                ctx.addPath(bubble)
                ctx.fillPath()
                ctx.setStrokeColor(a.colour.cgColor)
                ctx.setLineWidth(2)
                ctx.addPath(bubble)
                ctx.strokePath()
            }
            a.text?.draw(in: a.rect)
        case .counter:
            ctx.setFillColor(a.colour.cgColor)
            ctx.fillEllipse(in: a.rect)
            let label = NSAttributedString(string: "\(a.number)", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: contrastColour(on: a.colour),
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: a.rect.midX - size.width / 2, y: a.rect.midY - size.height / 2))
        case .redact:
            switch a.redactStyle {
            case .blackout:
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fill(a.rect)
            case .pixelate, .blur, .secure:
                if let patch = redactPatch {
                    blitFlipped(patch.image, in: patch.rect, ctx: ctx, canvasHeight: canvasHeight)
                } else {
                    // No patch = live drag on a big redact — placeholder so
                    // the shape stays visible while it renders at mouseUp.
                    ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
                    ctx.fill(a.rect)
                }
            }
        case .spotlight:
            // Rendered as a shared dim layer (drawSpotlightDim) so multiple
            // spotlights punch holes in ONE veil — nothing to draw per item.
            break
        case .image:
            if let ref = a.imageRef {
                blitFlipped(ref.image, in: a.rect, ctx: ctx, canvasHeight: canvasHeight)
            }
        case .magnifier:
            // Zoomed patch clipped to the loupe circle + connector to source.
            if let patch = redactPatch {
                ctx.saveGState()
                ctx.addEllipse(in: a.rect)
                ctx.clip()
                blitFlipped(patch.image, in: patch.rect, ctx: ctx, canvasHeight: canvasHeight)
                ctx.restoreGState()
            }
            let centre = CGPoint(x: a.rect.midX, y: a.rect.midY)
            let dx = centre.x - a.start.x
            let dy = centre.y - a.start.y
            let len = hypot(dx, dy)
            ctx.setStrokeColor(a.colour.cgColor)
            ctx.setLineWidth(max(a.lineWidth * 0.6, 1.5))
            if len > a.rect.width / 2 + 4 {
                // Stop the connector at the ring, not its centre.
                let f = (len - a.rect.width / 2) / len
                ctx.move(to: a.start)
                ctx.addLine(to: CGPoint(x: a.start.x + dx * f, y: a.start.y + dy * f))
                ctx.strokePath()
                ctx.setFillColor(a.colour.cgColor)
                ctx.fillEllipse(in: CGRect(
                    x: a.start.x - 2.5, y: a.start.y - 2.5, width: 5, height: 5))
            }
            ctx.setLineWidth(a.lineWidth)
            ctx.strokeEllipse(in: a.rect)
        case .sticker:
            if let emoji = a.text?.string, !emoji.isEmpty {
                // Sized by the rect, so the resize handles scale the emoji.
                let str = NSAttributedString(string: emoji, attributes: [
                    .font: NSFont.systemFont(ofSize: a.rect.height * 0.82),
                ])
                let size = str.size()
                str.draw(at: CGPoint(
                    x: a.rect.midX - size.width / 2, y: a.rect.midY - size.height / 2))
            }
        }
    }

    /// Tiled watermark: repeat the object across `cover` on a half-offset
    /// grid anchored at the object's own position (so dragging the original
    /// shifts the whole pattern). Non-tiled objects fall through to draw().
    static func drawTiled(
        _ a: AnnotatorAnnotation, in ctx: CGContext, canvasHeight: CGFloat, over cover: CGRect
    ) {
        guard a.tiled, a.rect.width > 1, a.rect.height > 1 else {
            draw(a, in: ctx, canvasHeight: canvasHeight, redactPatch: nil)
            return
        }
        let stepX = a.rect.width * 1.8
        let stepY = a.rect.height * 2.4
        let firstX = a.rect.minX - (((a.rect.minX - cover.minX) / stepX).rounded(.up)) * stepX
        let firstY = a.rect.minY - (((a.rect.minY - cover.minY) / stepY).rounded(.up)) * stepY
        var row = 0
        var y = firstY
        while y < cover.maxY {
            let rowShift = row % 2 == 0 ? 0 : stepX / 2   // brick-lay the rows
            var x = firstX - stepX + rowShift
            while x < cover.maxX {
                var tile = AnnotatorGeo.translate(a, by: CGPoint(x: x - a.rect.minX, y: y - a.rect.minY))
                tile.tiled = false
                draw(tile, in: ctx, canvasHeight: canvasHeight, redactPatch: nil)
                x += stepX
            }
            y += stepY
            row += 1
        }
    }

    /// One 45% veil with a hole per spotlight. Runs after redactions and
    /// before every other annotation, so arrows/text stay bright.
    static func drawSpotlightDim(
        spotlights: [CGRect], over veil: CGRect, in ctx: CGContext
    ) {
        guard !spotlights.isEmpty else { return }
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addRect(veil)
        for rect in spotlights {
            ctx.addRect(rect)
        }
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    private static func drawArrow(_ a: AnnotatorAnnotation, in ctx: CGContext) {
        let dx = a.end.x - a.start.x
        let dy = a.end.y - a.start.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let headLength = min(max(a.lineWidth * 4, 10), len / (a.arrowStyle == .double ? 2.5 : 1))

        ctx.setStrokeColor(a.colour.cgColor)
        ctx.setFillColor(a.colour.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)
        if a.arrowStyle == .dashed {
            ctx.setLineDash(phase: 0, lengths: [a.lineWidth * 3, a.lineWidth * 2.2])
        }

        switch a.arrowStyle {
        case .curved:
            // Quadratic bend, bowed perpendicular to the chord; the head
            // follows the curve's tangent at the tip.
            let mid = CGPoint(x: (a.start.x + a.end.x) / 2, y: (a.start.y + a.end.y) / 2)
            let ux = dx / len, uy = dy / len
            let control = CGPoint(x: mid.x - uy * len * 0.22, y: mid.y + ux * len * 0.22)
            let tangent = CGPoint(x: a.end.x - control.x, y: a.end.y - control.y)
            let tLen = max(hypot(tangent.x, tangent.y), 0.5)
            let tx = tangent.x / tLen, ty = tangent.y / tLen
            let shaftEnd = CGPoint(
                x: a.end.x - tx * headLength * 0.6, y: a.end.y - ty * headLength * 0.6)
            ctx.move(to: a.start)
            ctx.addQuadCurve(to: shaftEnd, control: control)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            fillHead(at: a.end, ux: tx, uy: ty, length: headLength, in: ctx)
        case .double:
            let ux = dx / len, uy = dy / len
            let shaftStart = CGPoint(
                x: a.start.x + ux * headLength * 0.6, y: a.start.y + uy * headLength * 0.6)
            let shaftEnd = CGPoint(
                x: a.end.x - ux * headLength * 0.6, y: a.end.y - uy * headLength * 0.6)
            ctx.move(to: shaftStart)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            fillHead(at: a.end, ux: ux, uy: uy, length: headLength, in: ctx)
            fillHead(at: a.start, ux: -ux, uy: -uy, length: headLength, in: ctx)
        case .straight, .dashed:
            let ux = dx / len, uy = dy / len
            // Stop the shaft short of the tip so the cap doesn't poke past the head.
            let shaftEnd = CGPoint(
                x: a.end.x - ux * headLength * 0.6, y: a.end.y - uy * headLength * 0.6)
            ctx.move(to: a.start)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            fillHead(at: a.end, ux: ux, uy: uy, length: headLength, in: ctx)
        }
    }

    private static func fillHead(
        at tip: CGPoint, ux: CGFloat, uy: CGFloat, length: CGFloat, in ctx: CGContext
    ) {
        let width = length * 0.85
        let base = CGPoint(x: tip.x - ux * length, y: tip.y - uy * length)
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: base.x - uy * width / 2, y: base.y + ux * width / 2))
        ctx.addLine(to: CGPoint(x: base.x + uy * width / 2, y: base.y - ux * width / 2))
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: Export composite

    /// Flatten base + annotations at native pixel scale, sized to the full
    /// canvas (annotations may spill past the image — margin exports as
    /// transparency). The CTM is scaled to points, flipped to top-left, and
    /// shifted so image-space coords land correctly; the exact canvas draw
    /// routine then runs unmodified (per research B5).
    static func composite(
        base: CGImage,
        scale: CGFloat,
        annotations: [AnnotatorAnnotation],
        patch: (AnnotatorAnnotation) -> (rect: CGRect, image: CGImage)?
    ) -> CGImage? {
        let imageSize = NSSize(
            width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale)
        let canvas = AnnotatorGeo.canvasBounds(imageSize: imageSize, annotations: annotations)
        guard let ctx = CGContext(
            data: nil,
            width: Int(canvas.width * scale), height: Int(canvas.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -canvas.minX, y: -canvas.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        blitFlipped(
            base, in: CGRect(origin: .zero, size: imageSize),
            ctx: ctx, canvasHeight: imageSize.height)
        for a in annotations where a.kind == .redact {
            draw(a, in: ctx, canvasHeight: imageSize.height, redactPatch: patch(a))
        }
        // Spotlights dim above redactions and below everything else.
        drawSpotlightDim(
            spotlights: annotations.filter { $0.kind == .spotlight }.map(\.rect),
            over: canvas,
            in: ctx)
        for a in annotations where a.kind != .redact && a.kind != .spotlight {
            if a.tiled {
                drawTiled(a, in: ctx, canvasHeight: imageSize.height, over: canvas)
            } else {
                draw(a, in: ctx, canvasHeight: imageSize.height,
                     redactPatch: a.kind == .magnifier ? patch(a) : nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

extension AnnotatorRender {
    /// Annotations-only render at EXACT image size — transparent where the
    /// base would be, no canvas growth. The video burn-in layer must align
    /// 1:1 with the frame, so spilled annotations clip instead of resizing.
    static func overlay(
        imageSize: NSSize,
        scale: CGFloat,
        annotations: [AnnotatorAnnotation],
        patch: (AnnotatorAnnotation) -> (rect: CGRect, image: CGImage)?
    ) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: Int(imageSize.width * scale), height: Int(imageSize.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: imageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let frame = CGRect(origin: .zero, size: imageSize)
        for a in annotations where a.kind == .redact {
            draw(a, in: ctx, canvasHeight: imageSize.height, redactPatch: patch(a))
        }
        drawSpotlightDim(
            spotlights: annotations.filter { $0.kind == .spotlight }.map(\.rect),
            over: frame, in: ctx)
        for a in annotations where a.kind != .redact && a.kind != .spotlight {
            if a.tiled {
                drawTiled(a, in: ctx, canvasHeight: imageSize.height, over: frame)
            } else {
                draw(a, in: ctx, canvasHeight: imageSize.height,
                     redactPatch: a.kind == .magnifier ? patch(a) : nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

// MARK: - Background export

extension AnnotatorRender {
    /// Wrap a flattened export in its background: padding, fill, shadow, and
    /// rounded corners — all in pixels, mirroring the live backdrop preview.
    static func applyBackground(
        _ style: AnnotatorBackgroundStyle, to image: CGImage, scale: CGFloat
    ) -> CGImage? {
        guard style.isVisible else { return image }
        let pad = style.padding * scale
        let width = Int(CGFloat(image.width) + pad * 2)
        let height = Int(CGFloat(image.height) + pad * 2)
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        style.drawFill(in: CGRect(x: 0, y: 0, width: width, height: height), ctx: ctx)

        let imageRect = CGRect(
            x: pad, y: pad, width: CGFloat(image.width), height: CGFloat(image.height))
        let radius = min(style.cornerRadius * scale, imageRect.width / 2, imageRect.height / 2)
        let rounded = CGPath(
            roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if style.shadow {
            // The shadow is cast by a solid stand-in; the image then draws
            // clipped on top (a clipped draw casts no shadow of its own).
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -pad * 0.12),
                blur: max(18 * scale, pad * 0.35),
                color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.addPath(rounded)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(rounded)
        ctx.clip()
        ctx.draw(image, in: imageRect)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

// MARK: - Redaction patches

/// Renders pixelate/blur patches from the BASE image only, via one CIContext.
/// Patches are cached by the canvas and regenerated only on geometry/style
/// change, so unrelated redraws never touch Core Image.
final class AnnotatorRedactRenderer {
    private let ciContext = CIContext()
    private var baseCI: CIImage
    private var pixelWidth: CGFloat
    private var pixelHeight: CGFloat
    private let scale: CGFloat

    init(base: CGImage, scale: CGFloat) {
        self.scale = scale
        baseCI = CIImage(cgImage: base)
        pixelWidth = CGFloat(base.width)
        pixelHeight = CGFloat(base.height)
    }

    func setBase(_ base: CGImage) {
        baseCI = CIImage(cgImage: base)
        pixelWidth = CGFloat(base.width)
        pixelHeight = CGFloat(base.height)
    }

    /// `rect` is in image points, top-left origin. Returns the patch and the
    /// (possibly clamped) point rect it covers — a redact dragged past the
    /// image edge must not hand Core Image an out-of-extent crop.
    func patch(
        forPointRect rect: CGRect, style: AnnotatorRedactStyle
    ) -> (rect: CGRect, image: CGImage)? {
        guard style != .blackout else { return nil }
        // Points (top-left) → pixels (bottom-left, Core Image space).
        let px = CGRect(
            x: rect.minX * scale,
            y: pixelHeight - rect.maxY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard !px.isEmpty, px.width >= 1, px.height >= 1 else { return nil }

        let output: CIImage
        switch style {
        case .blur:
            output = baseCI.clampedToExtent().applyingGaussianBlur(sigma: 14).cropped(to: px)
        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = baseCI.clampedToExtent()
            filter.center = .zero   // grid anchored to the image — stable while dragging
            filter.scale = Float(max(16, min(px.width, px.height) / 8))
            guard let out = filter.outputImage?.cropped(to: px) else { return nil }
            // Noise overlay: clean pixellation preserves exact cell averages,
            // which is enough to reverse small text — randomisation kills that.
            output = noised(out, over: px, alpha: 0.08)
        case .secure:
            // Belt and braces: coarse cells, then a heavy blur, then noise.
            let filter = CIFilter.pixellate()
            filter.inputImage = baseCI.clampedToExtent()
            filter.center = .zero
            filter.scale = Float(max(24, min(px.width, px.height) / 6))
            guard let pixellated = filter.outputImage else { return nil }
            let blurred = pixellated.clampedToExtent()
                .applyingGaussianBlur(sigma: 22).cropped(to: px)
            output = noised(blurred, over: px, alpha: 0.12)
        case .blackout:
            return nil
        }
        guard let cg = ciContext.createCGImage(output, from: px) else { return nil }
        // Back to top-left point coords for the draw routine.
        let pointRect = CGRect(
            x: px.minX / scale,
            y: (pixelHeight - px.maxY) / scale,
            width: px.width / scale,
            height: px.height / scale
        )
        return (pointRect, cg)
    }

    /// Loupe patch: the base region around `source` (rect.size/zoom points)
    /// scaled up to fill the loupe rect. Clamped extent covers loupes whose
    /// source hangs past the image edge.
    func magnifierPatch(
        rect: CGRect, source: CGPoint, zoom: CGFloat
    ) -> (rect: CGRect, image: CGImage)? {
        guard rect.width >= 2, rect.height >= 2, zoom >= 1 else { return nil }
        let px = CGRect(
            x: (source.x - rect.width / zoom / 2) * scale,
            y: pixelHeight - (source.y + rect.height / zoom / 2) * scale,
            width: rect.width / zoom * scale,
            height: rect.height / zoom * scale)
        let scaled = baseCI.clampedToExtent()
            .cropped(to: px)
            .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
        guard let cg = ImagePipeline.ciContext.createCGImage(scaled, from: scaled.extent)
        else { return nil }
        return (rect, cg)
    }

    /// Monochrome random noise composited over the patch — irreversibility
    /// comes from the noise being unknowable, not from its strength.
    private func noised(_ image: CIImage, over extent: CGRect, alpha: CGFloat) -> CIImage {
        guard let random = CIFilter.randomGenerator().outputImage else { return image }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = random
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
        guard let faded = matrix.outputImage?.cropped(to: extent) else { return image }
        return faded.composited(over: image)
    }
}
