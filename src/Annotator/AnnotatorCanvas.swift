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

    /// Tool / selection / text-editing changed — chrome should refresh.
    var onStateChange: (() -> Void)?
    /// Base image swapped (crop applied or undone) — dims/title should refresh.
    var onImageChanged: (() -> Void)?

    private let redactRenderer: AnnotatorRedactRenderer
    private var patchCache: [UUID: PatchEntry] = [:]

    private(set) var cropActive = false
    private var cropRect: CGRect = .zero

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
        for a in annotations where a.kind != .redact {
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
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1 / z)
        ctx.stroke(cropRect)
        for (_, p) in AnnotatorHit.rectHandles(cropRect) {
            drawHandle(at: p, in: ctx, zoom: z, accent: .controlAccentColor)
        }
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
            a.start = p
            a.end = p
            annotations.append(a)
            drag = .drawLine(id: a.id)
        case .rect, .filledRect, .ellipse, .redact:
            let kind: AnnotatorKind = switch tool {
            case .rect: .rect
            case .filledRect: .filledRect
            case .ellipse: .ellipse
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
        if let handle = AnnotatorHit.handleHit(
            AnnotatorHit.rectHandles(cropRect), at: p, slop: 12 / zoom) {
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
            cropRect = AnnotatorGeo.rect(from: anchor, to: clampedToCanvas(p))
            needsDisplay = true
        case .cropMove(let last):
            var r = cropRect
            r.origin.x = min(max(r.origin.x + p.x - last.x, 0), max(pointSize.width - r.width, 0))
            r.origin.y = min(max(r.origin.y + p.y - last.y, 0), max(pointSize.height - r.height, 0))
            cropRect = r
            drag = .cropMove(last: p)
            needsDisplay = true
        case .cropResize(let handle, let original):
            cropRect = AnnotatorHit.resize(original, handle: handle, to: clampedToCanvas(p))
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
            if let i = index(of: id), annotations[i].points.count < 2 {
                // A zero-length round-cap stroke renders nothing — make a dot.
                let p = annotations[i].points[0]
                annotations[i].points.append(CGPoint(x: p.x + 0.1, y: p.y))
                setNeedsDisplay(AnnotatorGeo.displayBounds(of: annotations[i]))
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
        setNeedsDisplay(before.union(AnnotatorGeo.displayBounds(of: annotations[i])))
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
                $0.text = AnnotatorRender.attributed(t.string, size: $0.textSize, colour: colour)
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
            tv.font = NSFont.systemFont(ofSize: size, weight: .semibold)
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
                $0.text = AnnotatorRender.attributed(t.string, size: size, colour: $0.colour)
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

        let tv = NSTextView(frame: frame)
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0   // match NSStringDrawing output (research B2)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: size, weight: .semibold)
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
            annotations[i].text = AnnotatorRender.attributed(string, size: a.textSize, colour: a.colour)
            annotations[i].rect = frame
            setNeedsDisplay(AnnotatorGeo.displayBounds(of: annotations[i]))
        } else {
            var a = AnnotatorAnnotation(kind: .text)
            a.rect = frame
            a.colour = currentColour
            a.textSize = currentTextSize
            a.text = AnnotatorRender.attributed(string, size: currentTextSize, colour: currentColour)
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
