import AppKit
import Carbon.HIToolbox

/// The editor canvas: a single flipped NSView whose coordinate space IS the
/// image's point space (research B1). Zoom/pan live entirely in the enclosing
/// NSScrollView; annotations are value types drawn via the shared routine.
final class AnnotatorCanvas: NSView, NSTextViewDelegate {
    private struct State {
        var base: CGImage
        var annotations: [AnnotatorAnnotation]
    }

    private struct PatchEntry {
        var sourceRect: CGRect
        var style: AnnotatorRedactStyle
        var patch: (rect: CGRect, image: CGImage)?
    }

    private enum Drag {
        case none
        case drawRect(id: UUID, anchor: CGPoint)
        case drawLine(id: UUID)
        case freehand(id: UUID)
        case move(id: UUID, last: CGPoint)
        // original anchors the whole gesture: resizing iteratively from
        // the current rect makes the fixed edge drift once the drag crosses
        // the opposite edge (the normalised rect swaps min/max under the
        // handle's feet).
        case resize(id: UUID, handle: AnnotatorHandle, original: CGRect)
        case cropNew(anchor: CGPoint)
        case cropMove(last: CGPoint)
        case cropResize(handle: AnnotatorHandle, original: CGRect)
    }

    // MARK: State

    private(set) var baseImage: CGImage
    let imageScale: CGFloat
    private(set) var annotations: [AnnotatorAnnotation] = []
    private(set) var selectedID: UUID?

    var tool: AnnotatorTool = .select {
        didSet { toolDidChange(from: oldValue) }
    }

    var currentColour: NSColor = .systemRed
    var currentLineWidth: CGFloat = 4
    var currentTextSize: CGFloat = 20
    var currentRedactStyle: AnnotatorRedactStyle = .pixelate
    var currentArrowStyle: AnnotatorArrowStyle = .straight
    var currentTextStyle: AnnotatorTextStyle = .standard

    /// Tool / selection / text-editing changed — chrome should refresh.
    var onStateChange: (() -> Void)?
    /// Base image swapped (crop applied or undone) — dims/title should refresh.
    var onImageChanged: (() -> Void)?

    private let redactRenderer: AnnotatorRedactRenderer
    private var patchCache: [UUID: PatchEntry] = [:]

    private(set) var cropActive = false
    private var cropRect: CGRect = .zero

    /// Width:height lock while cropping; nil = free. Setting it refits the
    /// current crop rect to the ratio, centred, as large as fits.
    var cropAspect: CGFloat? {
        didSet {
            guard cropActive, let aspect = cropAspect, aspect > 0 else {
                needsDisplay = true
                return
            }
            var w = cropRect.width
            var h = w / aspect
            if h > cropRect.height {
                h = cropRect.height
                w = h * aspect
            }
            w = min(w, pointSize.width)
            h = min(h, pointSize.height)
            var origin = CGPoint(x: cropRect.midX - w / 2, y: cropRect.midY - h / 2)
            origin.x = min(max(origin.x, 0), pointSize.width - w)
            origin.y = min(max(origin.y, 0), pointSize.height - h)
            cropRect = CGRect(origin: origin, size: CGSize(width: w, height: h))
            needsDisplay = true
        }
    }

    private var drag: Drag = .none
    private var preGesture: State?

    private var textEditor: NSTextView?
    private var editingTextID: UUID?
    private var preEditState: State?
    private var endingTextEdit = false
    private let textEditingUndoManager = UndoManager()

    var pointSize: NSSize {
        NSSize(width: CGFloat(baseImage.width) / imageScale, height: CGFloat(baseImage.height) / imageScale)
    }

    private var zoom: CGFloat {
        max(enclosingScrollView?.magnification ?? 1, 0.01)
    }

    // MARK: Init

    init(still: StillCapture) {
        baseImage = still.image
        imageScale = still.scale
        redactRenderer = AnnotatorRedactRenderer(base: still.image, scale: still.scale)
        super.init(frame: NSRect(origin: .zero, size: .zero))
        setFrameSize(pointSize)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        switch tool {
        case .select: break
        case .text: addCursorRect(bounds, cursor: .iBeam)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let h = pointSize.height
        // CG clips the blit to dirtyRect — a 40000 px scrolling capture only
        // decodes the visible band.
        AnnotatorRender.blitFlipped(
            baseImage, in: CGRect(origin: .zero, size: pointSize), ctx: ctx, canvasHeight: h)
        // Redactions always sit directly above the base, below everything else,
        // regardless of array order (research B3).
        for a in annotations where a.kind == .redact {
            guard AnnotatorGeo.displayBounds(of: a).intersects(dirtyRect) else { continue }
            AnnotatorRender.draw(a, in: ctx, canvasHeight: h, redactPatch: cachedPatch(for: a))
        }
        // Spotlights dim above redactions and below everything else. The
        // veil spans the whole canvas, so it redraws whenever any spotlight
        // exists and the dirty rect intersects anything.
        let spotlights = annotations.filter { $0.kind == .spotlight }.map(\.rect)
        AnnotatorRender.drawSpotlightDim(spotlights: spotlights, canvasSize: pointSize, in: ctx)
        for a in annotations where a.kind != .redact && a.kind != .spotlight {
            guard a.id != editingTextID,
                  AnnotatorGeo.displayBounds(of: a).intersects(dirtyRect) else { continue }
            AnnotatorRender.draw(a, in: ctx, canvasHeight: h, redactPatch: nil)
        }
        if !cropActive, let id = selectedID, let sel = annotation(id) {
            drawChrome(sel, in: ctx)
        }
        if cropActive {
            drawCropOverlay(in: ctx)
        }
    }

    private func cachedPatch(for a: AnnotatorAnnotation) -> (rect: CGRect, image: CGImage)? {
        guard a.redactStyle != .blackout else { return nil }
        if let entry = patchCache[a.id], entry.sourceRect == a.rect, entry.style == a.redactStyle {
            return entry.patch
        }
        // Live-dragging a big redact would run a Core Image render plus a
        // GPU-to-CPU readback per mouse event; the draw routine shows a
        // placeholder fill instead, and the real patch lands at mouseUp.
        if isLiveDragging(a.id),
           a.rect.width * a.rect.height * imageScale * imageScale > 4_000_000 {
            return nil
        }
        let patch = redactRenderer.patch(forPointRect: a.rect, style: a.redactStyle)
        patchCache[a.id] = PatchEntry(sourceRect: a.rect, style: a.redactStyle, patch: patch)
        return patch
    }

    private func isLiveDragging(_ id: UUID) -> Bool {
        switch drag {
        case .drawRect(let d, _), .move(let d, _), .resize(let d, _, _):
            return d == id
        default:
            return false
        }
    }

    private func drawChrome(_ a: AnnotatorAnnotation, in ctx: CGContext) {
        let z = zoom
        let accent = NSColor.controlAccentColor
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let handles = AnnotatorHit.handles(for: a)
        if handles.isEmpty {
            // Move-only kinds get a dashed marquee instead of handles.
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1 / z)
            ctx.setLineDash(phase: 0, lengths: [4 / z, 3 / z])
            ctx.stroke(AnnotatorGeo.bounds(of: a).insetBy(dx: -4 / z, dy: -4 / z))
            return
        }
        switch a.kind {
        case .line, .arrow:
            break
        default:
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1 / z)
            ctx.stroke(a.rect)
        }
        for (_, p) in handles {
            drawHandle(at: p, in: ctx, zoom: z, accent: accent)
        }
    }

    private func drawHandle(at p: CGPoint, in ctx: CGContext, zoom z: CGFloat, accent: NSColor) {
        let s = 8 / z
        let r = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1 / z)
        ctx.fill(r)
        ctx.stroke(r)
    }

    private func drawCropOverlay(in ctx: CGContext) {
        let z = zoom
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addRect(CGRect(origin: .zero, size: pointSize))
        ctx.addRect(cropRect)
        ctx.fillPath(using: .evenOdd)

        // Rule-of-thirds guides make alignment judgeable at a glance.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1 / z)
        for f in [1.0 / 3.0, 2.0 / 3.0] {
            let x = cropRect.minX + cropRect.width * f
            let y = cropRect.minY + cropRect.height * f
            ctx.move(to: CGPoint(x: x, y: cropRect.minY))
            ctx.addLine(to: CGPoint(x: x, y: cropRect.maxY))
            ctx.move(to: CGPoint(x: cropRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: cropRect.maxX, y: y))
        }
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1 / z)
        ctx.stroke(cropRect)

        // Big corner brackets + edge bars: crop affordances are grabbed, not
        // admired — they scale inversely with zoom to stay finger-sized.
        let arm = min(18 / z, cropRect.width / 3, cropRect.height / 3)
        let thick = 3 / z
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(thick)
        ctx.setLineCap(.square)
        let r = cropRect.insetBy(dx: -thick / 2, dy: -thick / 2)
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: r.minX, y: r.minY + arm), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX + arm, y: r.minY)),
            (CGPoint(x: r.maxX - arm, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + arm)),
            (CGPoint(x: r.maxX, y: r.maxY - arm), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX - arm, y: r.maxY)),
            (CGPoint(x: r.minX + arm, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - arm)),
        ]
        for (a, corner, b) in corners {
            ctx.move(to: a)
            ctx.addLine(to: corner)
            ctx.addLine(to: b)
        }
        ctx.strokePath()

        let bar = min(14 / z, cropRect.width / 3, cropRect.height / 3)
        ctx.setLineWidth(thick)
        for (handle, p) in AnnotatorHit.rectHandles(cropRect) {
            switch handle {
            case .top, .bottom:
                ctx.move(to: CGPoint(x: p.x - bar / 2, y: p.y))
                ctx.addLine(to: CGPoint(x: p.x + bar / 2, y: p.y))
            case .left, .right:
                ctx.move(to: CGPoint(x: p.x, y: p.y - bar / 2))
                ctx.addLine(to: CGPoint(x: p.x, y: p.y + bar / 2))
            default:
                continue
            }
        }
        ctx.strokePath()

        drawCropDimensions(in: ctx, zoom: z)
    }

    private func drawCropDimensions(in ctx: CGContext, zoom z: CGFloat) {
        let px = "\(Int((cropRect.width * imageScale).rounded())) × \(Int((cropRect.height * imageScale).rounded())) px"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11 / z, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: px, attributes: attributes)
        let size = text.size()
        let pad = 5 / z
        var origin = CGPoint(
            x: cropRect.maxX - size.width - pad * 2 - 4 / z,
            y: cropRect.maxY - size.height - pad * 2 - 4 / z)
        // Tiny crops: park the label just below instead of inside.
        if size.width + pad * 4 > cropRect.width || size.height + pad * 4 > cropRect.height {
            origin = CGPoint(x: cropRect.minX, y: cropRect.maxY + 4 / z)
        }
        let pill = CGRect(
            x: origin.x, y: origin.y,
            width: size.width + pad * 2, height: size.height + pad * 2)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        let path = CGPath(roundedRect: pill, cornerWidth: 4 / z, cornerHeight: 4 / z, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
        text.draw(at: CGPoint(x: pill.minX + pad, y: pill.minY + pad))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if textEditor != nil {
            // Click-away commits via textDidEndEditing; don't also start a gesture.
            window?.makeFirstResponder(self)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        preGesture = snapshot()

        if cropActive {
            cropMouseDown(at: p)
            return
        }

        switch tool {
        case .select:
            selectMouseDown(at: p, clickCount: event.clickCount)
        case .crop:
            break   // entering the tool activates crop mode; handled above
        case .text:
            beginTextEditing(at: p, existing: nil)
        case .counter:
            var a = AnnotatorAnnotation(kind: .counter)
            a.colour = currentColour
            a.number = annotations.filter { $0.kind == .counter }.count + 1
            let d = AnnotatorRender.counterDiameter
            a.rect = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
            annotations.append(a)
            setSelected(a.id)
            drag = .move(id: a.id, last: p)
            setNeedsDisplay(AnnotatorGeo.displayBounds(of: a))
        case .draw, .highlighter:
            var a = AnnotatorAnnotation(kind: tool == .draw ? .freehand : .highlighter)
            a.colour = currentColour
            a.lineWidth = tool == .draw ? currentLineWidth : AnnotatorRender.highlighterWidth
            a.points = [p]
            annotations.append(a)
            drag = .freehand(id: a.id)
        case .arrow, .line:
            var a = AnnotatorAnnotation(kind: tool == .arrow ? .arrow : .line)
            a.colour = currentColour
            a.lineWidth = currentLineWidth
            a.arrowStyle = currentArrowStyle
            a.start = p
            a.end = p
            annotations.append(a)
            drag = .drawLine(id: a.id)
        case .rect, .filledRect, .ellipse, .redact, .spotlight:
            let kind: AnnotatorKind = switch tool {
            case .rect: .rect
            case .filledRect: .filledRect
            case .ellipse: .ellipse
            case .spotlight: .spotlight
            default: .redact
            }
            var a = AnnotatorAnnotation(kind: kind)
            a.colour = currentColour
            a.lineWidth = currentLineWidth
            a.redactStyle = currentRedactStyle
            a.rect = CGRect(origin: p, size: .zero)
            annotations.append(a)
            drag = .drawRect(id: a.id, anchor: p)
        }
    }

    private func selectMouseDown(at p: CGPoint, clickCount: Int) {
        if let id = selectedID, let sel = annotation(id),
           let handle = AnnotatorHit.handleHit(AnnotatorHit.handles(for: sel), at: p, slop: 12 / zoom) {
            drag = .resize(id: id, handle: handle, original: sel.rect)
            return
        }
        // Topmost annotation wins — iterate the array reversed.
        if let hit = annotations.reversed().first(where: { AnnotatorHit.hitTest($0, at: p) }) {
            if clickCount == 2, hit.kind == .text {
                setSelected(hit.id)
                beginTextEditing(at: p, existing: hit.id)
                drag = .none
                return
            }
            setSelected(hit.id)
            drag = .move(id: hit.id, last: p)
        } else {
            setSelected(nil)
            drag = .none
        }
    }

    private func cropMouseDown(at p: CGPoint) {
        // Crop affordances are deliberately fat — 20pt effective targets.
        if let handle = AnnotatorHit.handleHit(
            AnnotatorHit.rectHandles(cropRect), at: p, slop: 20 / zoom) {
            drag = .cropResize(handle: handle, original: cropRect)
        } else if cropRect.contains(p) {
            drag = .cropMove(last: p)
        } else {
            cropRect = CGRect(origin: clampedToCanvas(p), size: .zero)
            drag = .cropNew(anchor: cropRect.origin)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            break
        case .drawRect(let id, let anchor):
            update(id) { $0.rect = AnnotatorGeo.rect(from: anchor, to: p) }
        case .drawLine(let id):
            update(id) { $0.end = p }
        case .freehand(let id):
            update(id) { $0.points.append(p) }
        case .move(let id, let last):
            let d = CGPoint(x: p.x - last.x, y: p.y - last.y)
            update(id) { $0 = AnnotatorGeo.translate($0, by: d) }
            drag = .move(id: id, last: p)
        case .resize(let id, let handle, let original):
            update(id) {
                switch handle {
                case .lineStart: $0.start = p
                case .lineEnd: $0.end = p
                default: $0.rect = AnnotatorHit.resize(original, handle: handle, to: p)
                }
            }
        case .cropNew(let anchor):
            let target = clampedToCanvas(p)
            if let aspect = cropAspect {
                cropRect = aspectRect(from: anchor, to: target, aspect: aspect)
                    .intersection(CGRect(origin: .zero, size: pointSize))
            } else {
                cropRect = snappedCrop(AnnotatorGeo.rect(from: anchor, to: target))
            }
            needsDisplay = true
        case .cropMove(let last):
            var r = cropRect
            r.origin.x = min(max(r.origin.x + p.x - last.x, 0), max(pointSize.width - r.width, 0))
            r.origin.y = min(max(r.origin.y + p.y - last.y, 0), max(pointSize.height - r.height, 0))
            cropRect = r
            drag = .cropMove(last: p)
            needsDisplay = true
        case .cropResize(let handle, let original):
            cropRect = cropResized(original: original, handle: handle, to: clampedToCanvas(p))
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .drawRect(let id, _):
            if let a = annotation(id), a.rect.width < 3, a.rect.height < 3 {
                removeAnnotation(id)
            } else {
                setSelected(id)
            }
        case .drawLine(let id):
            if let a = annotation(id), hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 3 {
                removeAnnotation(id)
            } else {
                setSelected(id)
            }
        case .freehand(let id):
            if let i = index(of: id) {
                let before = AnnotatorGeo.displayBounds(of: annotations[i])
                if annotations[i].points.count < 2 {
                    // A zero-length round-cap stroke renders nothing — make a dot.
                    let p = annotations[i].points[0]
                    annotations[i].points.append(CGPoint(x: p.x + 0.1, y: p.y))
                } else {
                    annotations[i].points = AnnotatorGeo.smoothed(annotations[i].points)
                    // Highlighter runs that read as "underlining a line of
                    // text" snap to a clean horizontal band.
                    if annotations[i].kind == .highlighter,
                       let band = AnnotatorGeo.horizontalBand(annotations[i].points) {
                        annotations[i].points = band
                    }
                }
                setNeedsDisplay(before.union(AnnotatorGeo.displayBounds(of: annotations[i])))
            }
        case .cropNew:
            if cropRect.width < 10 || cropRect.height < 10 {
                cropRect = CGRect(origin: .zero, size: pointSize)
                needsDisplay = true
            }
        default:
            break
        }
        finishGesture(name: gestureName())
        // A big redact drew a placeholder during the drag — with the gesture
        // over, redraw so the real patch renders.
        if case .drawRect(let id, _) = drag, let a = annotation(id), a.kind == .redact {
            drag = .none
            setNeedsDisplay(AnnotatorGeo.displayBounds(of: a))
        } else if case .move(let id, _) = drag, let a = annotation(id), a.kind == .redact {
            drag = .none
            setNeedsDisplay(AnnotatorGeo.displayBounds(of: a))
        } else if case .resize(let id, _, _) = drag, let a = annotation(id), a.kind == .redact {
            drag = .none
            setNeedsDisplay(AnnotatorGeo.displayBounds(of: a))
        } else {
            drag = .none
        }
    }

    private func gestureName() -> String {
        switch drag {
        case .move: return "Move"
        case .resize: return "Resize"
        case .drawRect, .drawLine, .freehand: return "Draw"
        default: return "Edit"
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let code = Int(event.keyCode)
        if cropActive {
            switch code {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                commitCrop()
                return
            case kVK_Escape:
                cancelCrop()
                return
            default:
                break
            }
        }
        switch code {
        case kVK_Escape:
            setSelected(nil)   // swallow even when nothing selected — no beep
        case kVK_Delete, kVK_ForwardDelete:
            deleteSelected()
        case kVK_LeftArrow:
            nudge(dx: -1, dy: 0, big: event.modifierFlags.contains(.shift))
        case kVK_RightArrow:
            nudge(dx: 1, dy: 0, big: event.modifierFlags.contains(.shift))
        case kVK_UpArrow:
            nudge(dx: 0, dy: -1, big: event.modifierFlags.contains(.shift))
        case kVK_DownArrow:
            nudge(dx: 0, dy: 1, big: event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)   // bubbles to the window for tool letters
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat, big: Bool) {
        guard let id = selectedID else { return }
        let step: CGFloat = big ? 10 : 1
        let pre = snapshot()
        update(id) { $0 = AnnotatorGeo.translate($0, by: CGPoint(x: dx * step, y: dy * step)) }
        registerUndo(pre, name: "Nudge")
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        let pre = snapshot()
        removeAnnotation(id)
        setSelected(nil)
        registerUndo(pre, name: "Delete")
    }

    // MARK: Selection / mutation helpers

    private func annotation(_ id: UUID?) -> AnnotatorAnnotation? {
        guard let id else { return nil }
        return annotations.first { $0.id == id }
    }

    var selectedAnnotation: AnnotatorAnnotation? { annotation(selectedID) }

    private func index(of id: UUID) -> Int? {
        annotations.firstIndex { $0.id == id }
    }

    private func setSelected(_ id: UUID?) {
        guard id != selectedID else { return }
        if let old = annotation(selectedID) {
            setNeedsDisplay(AnnotatorGeo.displayBounds(of: old))
        }
        selectedID = id
        if let new = annotation(id) {
            setNeedsDisplay(AnnotatorGeo.displayBounds(of: new))
        }
        onStateChange?()
    }

    private func update(_ id: UUID, _ mutate: (inout AnnotatorAnnotation) -> Void) {
        guard let i = index(of: id) else { return }
        let before = AnnotatorGeo.displayBounds(of: annotations[i])
        mutate(&annotations[i])
        if annotations[i].kind == .spotlight {
            needsDisplay = true   // the veil covers the whole canvas
        } else {
            setNeedsDisplay(before.union(AnnotatorGeo.displayBounds(of: annotations[i])))
        }
    }

    private func removeAnnotation(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let bounds = AnnotatorGeo.displayBounds(of: annotations[i])
        annotations.remove(at: i)
        patchCache.removeValue(forKey: id)
        renumberCounters()
        setNeedsDisplay(bounds)
    }

    private func renumberCounters() {
        var n = 1
        for i in annotations.indices where annotations[i].kind == .counter {
            if annotations[i].number != n {
                annotations[i].number = n
                setNeedsDisplay(AnnotatorGeo.displayBounds(of: annotations[i]))
            }
            n += 1
        }
    }

    private func clampedToCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), pointSize.width), y: min(max(p.y, 0), pointSize.height))
    }

    // MARK: Crop geometry

    /// Anchor-fixed rect obeying a width:height ratio; the dominant drag axis
    /// wins so the rect tracks the cursor naturally.
    private func aspectRect(from anchor: CGPoint, to p: CGPoint, aspect: CGFloat) -> CGRect {
        let sx: CGFloat = p.x < anchor.x ? -1 : 1
        let sy: CGFloat = p.y < anchor.y ? -1 : 1
        var dx = abs(p.x - anchor.x)
        var dy = abs(p.y - anchor.y)
        if dx / aspect >= dy {
            dy = dx / aspect
        } else {
            dx = dy * aspect
        }
        return CGRect(
            x: min(anchor.x, anchor.x + sx * dx),
            y: min(anchor.y, anchor.y + sy * dy),
            width: dx, height: dy)
    }

    private func cropResized(original: CGRect, handle: AnnotatorHandle, to p: CGPoint) -> CGRect {
        guard let aspect = cropAspect, aspect > 0 else {
            return snappedCrop(AnnotatorHit.resize(original, handle: handle, to: p))
        }
        let constrained: CGRect
        switch handle {
        case .topLeft:
            constrained = aspectRect(from: CGPoint(x: original.maxX, y: original.maxY), to: p, aspect: aspect)
        case .topRight:
            constrained = aspectRect(from: CGPoint(x: original.minX, y: original.maxY), to: p, aspect: aspect)
        case .bottomLeft:
            constrained = aspectRect(from: CGPoint(x: original.maxX, y: original.minY), to: p, aspect: aspect)
        case .bottomRight:
            constrained = aspectRect(from: CGPoint(x: original.minX, y: original.minY), to: p, aspect: aspect)
        case .top, .bottom:
            var r = AnnotatorHit.resize(original, handle: handle, to: p)
            let w = r.height * aspect
            r.origin.x = original.midX - w / 2
            r.size.width = w
            constrained = r
        case .left, .right:
            var r = AnnotatorHit.resize(original, handle: handle, to: p)
            let h = r.width / aspect
            r.origin.y = original.midY - h / 2
            r.size.height = h
            constrained = r
        case .lineStart, .lineEnd:
            constrained = original
        }
        return constrained.intersection(CGRect(origin: .zero, size: pointSize))
    }

    /// Free-crop edges glue to the image edges within 8pt — releasing a hair
    /// short of the border is the most common crop miss.
    private func snappedCrop(_ r: CGRect) -> CGRect {
        let tolerance = 8 / zoom
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        if abs(minX) < tolerance { minX = 0 }
        if abs(minY) < tolerance { minY = 0 }
        if abs(maxX - pointSize.width) < tolerance { maxX = pointSize.width }
        if abs(maxY - pointSize.height) < tolerance { maxY = pointSize.height }
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
    }

    // MARK: Style application (options bar)

    func applyColour(_ colour: NSColor) {
        currentColour = colour
        if let tv = textEditor {
            tv.textColor = colour
            tv.insertionPointColor = colour
            // Commit rebuilds an existing annotation's string from its stored
            // fields — persist the choice or it silently reverts on commit.
            if let id = editingTextID, let i = index(of: id) {
                annotations[i].colour = colour
            }
            return
        }
        guard let id = selectedID else { return }
        let pre = snapshot()
        update(id) {
            $0.colour = colour
            if $0.kind == .text, let t = $0.text {
                $0.text = AnnotatorRender.attributed(
                    t.string, size: $0.textSize, colour: colour, style: $0.textStyle)
            }
        }
        registerUndoIfChanged(pre, name: "Colour")
    }

    func applyLineWidth(_ width: CGFloat) {
        currentLineWidth = width
        guard let id = selectedID, let a = annotation(id),
              a.kind != .highlighter, a.kind != .text, a.kind != .counter, a.kind != .redact
        else { return }
        let pre = snapshot()
        update(id) { $0.lineWidth = width }
        registerUndoIfChanged(pre, name: "Stroke Width")
    }

    func applyTextSize(_ size: CGFloat) {
        currentTextSize = size
        if let tv = textEditor {
            let style = editingTextID.flatMap { id in
                index(of: id).map { annotations[$0].textStyle }
            } ?? currentTextStyle
            tv.font = style.font(size: size)
            if let id = editingTextID, let i = index(of: id) {
                annotations[i].textSize = size
            }
            growTextEditor()
            return
        }
        guard let id = selectedID, let a = annotation(id), a.kind == .text else { return }
        let pre = snapshot()
        update(id) {
            $0.textSize = size
            if let t = $0.text {
                $0.text = AnnotatorRender.attributed(
                    t.string, size: size, colour: $0.colour, style: $0.textStyle)
            }
        }
        registerUndoIfChanged(pre, name: "Text Size")
    }

    func applyRedactStyle(_ style: AnnotatorRedactStyle) {
        currentRedactStyle = style
        guard let id = selectedID, let a = annotation(id), a.kind == .redact else { return }
        let pre = snapshot()
        update(id) { $0.redactStyle = style }
        registerUndoIfChanged(pre, name: "Redact Style")
    }

    func applyArrowStyle(_ style: AnnotatorArrowStyle) {
        currentArrowStyle = style
        guard let id = selectedID, let a = annotation(id), a.kind == .arrow else { return }
        let pre = snapshot()
        update(id) { $0.arrowStyle = style }
        registerUndoIfChanged(pre, name: "Arrow Style")
    }

    func applyTextStyle(_ style: AnnotatorTextStyle) {
        currentTextStyle = style
        if let tv = textEditor {
            let size = editingTextID.flatMap { id in
                index(of: id).map { annotations[$0].textSize }
            } ?? currentTextSize
            tv.font = style.font(size: size)
            if let id = editingTextID, let i = index(of: id) {
                annotations[i].textStyle = style
            }
            growTextEditor()
            return
        }
        guard let id = selectedID, let a = annotation(id), a.kind == .text else { return }
        let pre = snapshot()
        update(id) {
            $0.textStyle = style
            if let t = $0.text {
                $0.text = AnnotatorRender.attributed(
                    t.string, size: $0.textSize, colour: $0.colour, style: style)
            }
        }
        registerUndoIfChanged(pre, name: "Text Style")
    }

    // MARK: Tool changes

    private func toolDidChange(from old: AnnotatorTool) {
        if textEditor != nil { commitTextEditing() }
        if old == .crop, tool != .crop {
            cropActive = false
            needsDisplay = true
        }
        if tool == .crop {
            cropActive = true
            cropRect = CGRect(origin: .zero, size: pointSize)
            setSelected(nil)
            needsDisplay = true
        } else if tool != .select {
            setSelected(nil)
        }
        window?.invalidateCursorRects(for: self)
        onStateChange?()
    }

    // MARK: Crop

    func commitCrop() {
        guard cropActive else { return }
        let px = CGRect(
            x: cropRect.minX * imageScale,
            y: cropRect.minY * imageScale,
            width: cropRect.width * imageScale,
            height: cropRect.height * imageScale
        ).integral.intersection(CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
        guard px.width >= 1, px.height >= 1, let cropped = baseImage.cropping(to: px) else {
            tool = .select
            return
        }
        let pre = snapshot()
        let origin = CGPoint(x: px.minX / imageScale, y: px.minY / imageScale)
        let newSize = NSSize(width: px.width / imageScale, height: px.height / imageScale)
        annotations = annotations.compactMap { a in
            let t = AnnotatorGeo.translate(a, by: CGPoint(x: -origin.x, y: -origin.y))
            let inside = AnnotatorGeo.bounds(of: t)
                .intersects(CGRect(origin: .zero, size: newSize))
            return inside ? t : nil
        }
        renumberCounters()
        baseImage = cropped
        redactRenderer.setBase(cropped)
        patchCache.removeAll()
        setFrameSize(pointSize)
        registerUndo(pre, name: "Crop")
        needsDisplay = true
        onImageChanged?()
        tool = .select
    }

    func cancelCrop() {
        guard cropActive else { return }
        tool = .select
    }

    // MARK: Text editing

    var isEditingText: Bool { textEditor != nil }

    func commitTextEditingIfAny() {
        if textEditor != nil { commitTextEditing() }
    }

    private func beginTextEditing(at point: CGPoint, existing id: UUID?) {
        commitTextEditingIfAny()
        preEditState = snapshot()
        editingTextID = id
        textEditingUndoManager.removeAllActions()

        let colour: NSColor
        let size: CGFloat
        var frame: CGRect
        var content: NSAttributedString?
        if let id, let a = annotation(id) {
            colour = a.colour
            size = a.textSize
            frame = a.rect
            content = a.text
            setNeedsDisplay(AnnotatorGeo.displayBounds(of: a))   // hide the committed render
        } else {
            colour = currentColour
            size = currentTextSize
            frame = CGRect(x: point.x, y: point.y - size * 0.7, width: 20, height: size * 1.5)
        }

        let editorStyle = id.flatMap { id in
            index(of: id).map { annotations[$0].textStyle }
        } ?? currentTextStyle
        let tv = NSTextView(frame: frame)
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0   // match NSStringDrawing output (research B2)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = editorStyle.font(size: size)
        tv.textColor = colour
        tv.insertionPointColor = colour
        tv.delegate = self
        if let content { tv.textStorage?.setAttributedString(content) }
        tv.textContainer?.widthTracksTextView = id != nil
        if id == nil {
            tv.textContainer?.containerSize = NSSize(
                width: max(bounds.width - frame.minX, 40), height: .greatestFiniteMagnitude)
        }
        addSubview(tv)
        textEditor = tv
        window?.makeFirstResponder(tv)
        growTextEditor()
        onStateChange?()
    }

    private func growTextEditor() {
        guard let tv = textEditor, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).size
        let lineHeight = (tv.font.map { lm.defaultLineHeight(for: $0) }) ?? 20
        let width = editingTextID == nil
            ? min(max(used.width + 4, 24), max(bounds.width - tv.frame.minX, 24))
            : tv.frame.width
        tv.setFrameSize(NSSize(width: width, height: max(used.height, lineHeight)))
    }

    func textDidChange(_ notification: Notification) {
        growTextEditor()
    }

    func textDidEndEditing(_ notification: Notification) {
        commitTextEditing()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextEditing()   // Esc commits (spec) — typed text is never lost
            return true
        }
        return false
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        // Keep typing undo out of the canvas undo stack while an editor is up.
        textEditingUndoManager
    }

    private func commitTextEditing() {
        guard let tv = textEditor, !endingTextEdit else { return }
        endingTextEdit = true
        defer { endingTextEdit = false }

        let string = tv.string
        let frame = tv.frame
        tv.delegate = nil
        tv.removeFromSuperview()
        textEditor = nil

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let id = editingTextID { removeAnnotation(id) }
        } else if let id = editingTextID, let i = index(of: id) {
            let a = annotations[i]
            annotations[i].text = AnnotatorRender.attributed(
                string, size: a.textSize, colour: a.colour, style: a.textStyle)
            annotations[i].rect = frame
            setNeedsDisplay(AnnotatorGeo.displayBounds(of: annotations[i]))
        } else {
            var a = AnnotatorAnnotation(kind: .text)
            a.rect = frame
            a.colour = currentColour
            a.textSize = currentTextSize
            a.textStyle = currentTextStyle
            a.text = AnnotatorRender.attributed(
                string, size: currentTextSize, colour: currentColour, style: currentTextStyle)
            annotations.append(a)
            setSelected(a.id)
            setNeedsDisplay(AnnotatorGeo.displayBounds(of: a))
        }
        if let pre = preEditState {
            registerUndoIfChanged(pre, name: "Edit Text")
        }
        preEditState = nil
        editingTextID = nil
        window?.makeFirstResponder(self)
        onStateChange?()
    }

    private func discardTextEditing() {
        guard let tv = textEditor else { return }
        endingTextEdit = true
        tv.delegate = nil
        tv.removeFromSuperview()
        endingTextEdit = false
        textEditor = nil
        preEditState = nil
        editingTextID = nil
    }

    // MARK: Undo

    private func snapshot() -> State {
        State(base: baseImage, annotations: annotations)
    }

    private func finishGesture(name: String) {
        defer { preGesture = nil }
        guard let pre = preGesture else { return }
        registerUndoIfChanged(pre, name: name)
    }

    private func registerUndoIfChanged(_ old: State, name: String) {
        guard old.annotations != annotations || old.base !== baseImage else { return }
        registerUndo(old, name: name)
    }

    /// One whole-state snapshot per completed gesture (research B4). The redo
    /// side falls out of re-registering the current state inside the closure.
    private func registerUndo(_ old: State, name: String) {
        undoManager?.registerUndo(withTarget: self) { canvas in
            MainActor.assumeIsolated {
                let current = canvas.snapshot()
                canvas.registerUndo(current, name: name)
                canvas.restore(old)
            }
        }
        undoManager?.setActionName(name)
    }

    private func restore(_ state: State) {
        discardTextEditing()
        let baseChanged = state.base !== baseImage
        baseImage = state.base
        annotations = state.annotations
        selectedID = nil
        patchCache.removeAll()
        if baseChanged {
            redactRenderer.setBase(state.base)
            setFrameSize(pointSize)
            // A live crop rect sized for the old base would dangle off-canvas.
            if cropActive { cropRect = CGRect(origin: .zero, size: pointSize) }
            onImageChanged?()
        }
        needsDisplay = true
        onStateChange?()
    }

    // MARK: Export

    /// Flatten the current state at native pixel scale — selection chrome and
    /// any in-flight text editor are excluded by construction.
    func flattened() -> CGImage? {
        AnnotatorRender.composite(base: baseImage, scale: imageScale, annotations: annotations) {
            cachedPatch(for: $0)
        }
    }
}
