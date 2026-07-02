import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// Full-screen selection chrome: dims every display, hover-highlights windows,
/// and rubber-bands an area selection. Hands back a Selection in global CG
/// top-left points; the capture engine excludes this process's windows from
/// the shot, so the overlay never needs to hide itself before capture.
@MainActor
final class SelectionController {
    static let shared = SelectionController()

    enum Mode { case still, window, record, scrolling, ocr, pin }

    struct Selection {
        let rect: CGRect        // global CG top-left-origin points
        let window: SCWindow?   // non-nil when the user picked a window
        let display: SCDisplay  // the display containing the selection
    }

    private(set) var isActive = false

    private init() {}

    // MARK: Session state — every rect/point below is global CG top-left points

    private var completion: ((Selection?) -> Void)?
    private var panels: [SelectionOverlayPanel] = []
    private var views: [SelectionOverlayView] = []
    /// Bumped on begin/finish so an in-flight content fetch from a previous
    /// session can never leak into the current one.
    private var generation = 0
    private var cursorPushed = false
    private var refetchTimer: Timer?
    private var refetchInFlight = false
    private var screenObserver: NSObjectProtocol?

    private var mode: Mode = .still
    private var content: SCShareableContent?
    fileprivate var mouseCG: CGPoint = .zero
    fileprivate var hoverWindow: SCWindow?
    fileprivate var isDragging = false

    private var dragPending = false
    private var dragAnchor: CGPoint = .zero
    private var dragCurrent: CGPoint = .zero
    private var dragClampFrame: CGRect = .zero
    private var dragDisplay: SCDisplay?
    private var lastMouseCG: CGPoint = .zero
    private var shiftHeld = false
    private var spaceHeld = false

    /// Last completed selection rect — Return re-captures it (CleanShot's
    /// "capture previous area"). Survives across invocations within this run.
    private static var lastRect: CGRect?

    private var windowPickAllowed: Bool {
        switch mode {
        case .still, .window, .record: return true
        case .scrolling, .ocr, .pin: return false
        }
    }

    fileprivate var hintText: String {
        switch mode {
        case .still, .record: return "Drag to select — click a window — Esc cancels"
        case .window: return "Click a window — drag to select — Esc cancels"
        case .ocr: return "Drag over text — Esc cancels"
        case .scrolling, .pin: return "Drag to select — Esc cancels"
        }
    }

    // MARK: Lifecycle

    func begin(mode: Mode, completion: @escaping (Selection?) -> Void) {
        guard !isActive else { return }
        isActive = true
        self.mode = mode
        self.completion = completion
        generation += 1
        let gen = generation
        Task { @MainActor in
            do {
                // Fetched per session, never cached across invocations: window
                // frames and z-order are stale the moment the user acts.
                let fetched = try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: true)
                guard self.isActive, self.generation == gen else { return }
                self.content = fetched
                self.presentOverlay()
            } catch {
                guard self.isActive, self.generation == gen else { return }
                NSLog("selection overlay: shareable content fetch failed: \(error.localizedDescription)")
                self.finish(with: nil)
            }
        }
    }

    private func presentOverlay() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            finish(with: nil)
            return
        }

        mouseCG = Coords.cgPoint(fromAppKit: NSEvent.mouseLocation)
        lastMouseCG = mouseCG
        hoverWindow = windowUnder(mouseCG)

        for screen in screens {
            let panel = SelectionOverlayPanel(screen: screen)
            let view = SelectionOverlayView(screen: screen, controller: self)
            panel.contentView = view
            panels.append(panel)
            views.append(view)
        }

        NSCursor.crosshair.push()
        cursorPushed = true

        // The panel under the mouse becomes key so Esc/Return land straight
        // away; the rest only order front. .nonactivatingPanel keeps the
        // frontmost app active throughout.
        let mouseAppKit = NSEvent.mouseLocation
        let keyIndex = screens.firstIndex { NSMouseInRect(mouseAppKit, $0.frame, false) } ?? 0
        for (i, panel) in panels.enumerated() where i != keyIndex {
            panel.orderFrontRegardless()
        }
        panels[keyIndex].makeKeyAndOrderFront(nil)
        for (i, panel) in panels.enumerated() {
            panel.makeFirstResponder(views[i])
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            // Display arrangement changed under us — every cached frame is wrong.
            MainActor.assumeIsolated { SelectionController.shared.finish(with: nil) }
        }

        if windowPickAllowed {
            refetchTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { _ in
                MainActor.assumeIsolated { SelectionController.shared.refetchContent() }
            }
        }
    }

    private func finish(with selection: Selection?) {
        guard isActive else { return }
        isActive = false
        generation += 1

        refetchTimer?.invalidate()
        refetchTimer = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil

        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        views.removeAll()

        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }

        content = nil
        hoverWindow = nil
        isDragging = false
        dragPending = false
        dragDisplay = nil
        spaceHeld = false
        shiftHeld = false

        if let selection {
            SelectionController.lastRect = selection.rect
        }
        let completion = self.completion
        self.completion = nil
        completion?(selection)
    }

    // MARK: Shareable content

    private func refetchContent() {
        guard isActive, !refetchInFlight else { return }
        refetchInFlight = true
        let gen = generation
        Task { @MainActor in
            defer { self.refetchInFlight = false }
            guard let fetched = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true) else { return }
            guard self.isActive, self.generation == gen else { return }
            self.content = fetched
            self.updateHover(force: true)
        }
    }

    private func windowUnder(_ p: CGPoint) -> SCWindow? {
        guard windowPickAllowed, let content else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        // content.windows is front-to-back, so the first hit is the topmost.
        return content.windows.first { w in
            w.windowLayer == 0 && w.isOnScreen
                && w.frame.width > 50 && w.frame.height > 50
                && w.owningApplication?.processID != pid
                && w.frame.contains(p)
        }
    }

    private func updateHover(force: Bool = false) {
        let newHover = isDragging ? nil : windowUnder(mouseCG)
        guard force || newHover?.windowID != hoverWindow?.windowID else { return }
        let old = hoverWindow?.frame
        hoverWindow = newHover
        invalidate(cg: old)
        invalidate(cg: hoverWindow?.frame)
    }

    // MARK: Drag geometry

    fileprivate func currentDragRect() -> CGRect {
        var dx = dragCurrent.x - dragAnchor.x
        var dy = dragCurrent.y - dragAnchor.y
        if shiftHeld {
            // Constrain to a square, shrunk when the display edge is closer
            // than the larger axis reaches.
            let f = dragClampFrame
            let availX = dx >= 0 ? f.maxX - dragAnchor.x : dragAnchor.x - f.minX
            let availY = dy >= 0 ? f.maxY - dragAnchor.y : dragAnchor.y - f.minY
            let side = min(max(abs(dx), abs(dy)), availX, availY)
            dx = dx >= 0 ? side : -side
            dy = dy >= 0 ? side : -side
        }
        return CGRect(
            x: min(dragAnchor.x, dragAnchor.x + dx),
            y: min(dragAnchor.y, dragAnchor.y + dy),
            width: abs(dx),
            height: abs(dy))
    }

    // MARK: Mouse (points arrive from the views already in global CG space)

    fileprivate func handleMouseMoved(to p: CGPoint) {
        guard isActive, !isDragging, !dragPending else { return }
        let old = mouseCG
        mouseCG = p
        lastMouseCG = p
        invalidateCursorChrome(at: old)
        invalidateCursorChrome(at: p)
        let oldView = view(containing: old)
        let newView = view(containing: p)
        if oldView !== newView {
            oldView?.invalidateHintArea()
            newView?.invalidateHintArea()
        }
        updateHover()
    }

    fileprivate func handleMouseDown(at p: CGPoint, on view: SelectionOverlayView) {
        guard isActive, !isDragging else { return }
        mouseCG = p
        lastMouseCG = p
        updateHover()   // a click with no prior movement still picks the right window
        dragPending = true
        dragAnchor = p
        dragCurrent = p
        dragDisplay = content?.displays.first { $0.displayID == view.displayID }
            ?? content?.displays.first { $0.frame.contains(p) }
        dragClampFrame = dragDisplay?.frame ?? view.screenFrameCG
    }

    fileprivate func handleMouseDragged(to p: CGPoint, shift: Bool) {
        guard isActive, dragPending || isDragging else { return }
        shiftHeld = shift
        if !isDragging {
            // Below the click-vs-drag threshold this is still a window pick.
            guard hypot(p.x - dragAnchor.x, p.y - dragAnchor.y) >= 4 else {
                lastMouseCG = p
                return
            }
            beginDrag()
        }
        let oldRect = currentDragRect()
        let f = dragClampFrame
        if spaceHeld {
            // Space slides the in-progress rect instead of resizing it.
            var dx = p.x - lastMouseCG.x
            var dy = p.y - lastMouseCG.y
            dx = min(max(dx, f.minX - oldRect.minX), f.maxX - oldRect.maxX)
            dy = min(max(dy, f.minY - oldRect.minY), f.maxY - oldRect.maxY)
            dragAnchor.x += dx
            dragAnchor.y += dy
            dragCurrent.x += dx
            dragCurrent.y += dy
        } else {
            dragCurrent = CGPoint(
                x: min(max(p.x, f.minX), f.maxX),
                y: min(max(p.y, f.minY), f.maxY))
        }
        lastMouseCG = p
        invalidateSelection(from: oldRect, to: currentDragRect())
    }

    fileprivate func handleMouseUp(at p: CGPoint) {
        guard isActive else { return }
        defer { dragPending = false }
        if isDragging {
            let rect = currentDragRect()
            if rect.width >= 4, rect.height >= 4,
               let display = dragDisplay
                   ?? content.flatMap({ CaptureEngine.shared.display(containing: rect, in: $0) }) {
                finish(with: Selection(rect: rect, window: nil, display: display))
            } else {
                resetToIdle(at: p)
            }
        } else if windowPickAllowed,
                  let picked = hoverWindow ?? windowUnder(p),
                  let content,
                  let display = CaptureEngine.shared.display(containing: picked.frame, in: content) {
            finish(with: Selection(rect: picked.frame, window: picked, display: display))
        } else {
            resetToIdle(at: p)
        }
    }

    private func beginDrag() {
        isDragging = true
        let oldHover = hoverWindow
        hoverWindow = nil
        invalidate(cg: oldHover?.frame)
        invalidateCursorChrome(at: mouseCG)
        view(containing: mouseCG)?.invalidateHintArea()
    }

    private func resetToIdle(at p: CGPoint) {
        isDragging = false
        dragPending = false
        mouseCG = p
        lastMouseCG = p
        for v in views {
            v.needsDisplay = true
        }
        updateHover(force: true)
    }

    // MARK: Keyboard (arrives via whichever panel is key)

    fileprivate func handleKeyDown(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            finish(with: nil)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            repeatLastArea()
        case kVK_Space:
            if !event.isARepeat { spaceHeld = true }
        default:
            break
        }
    }

    fileprivate func handleKeyUp(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Space { spaceHeld = false }
    }

    fileprivate func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        let newShift = flags.contains(.shift)
        guard newShift != shiftHeld else { return }
        let old = currentDragRect()
        shiftHeld = newShift
        if isDragging {
            invalidateSelection(from: old, to: currentDragRect())
        }
    }

    private func repeatLastArea() {
        guard !isDragging, !dragPending,
              let rect = SelectionController.lastRect,
              let content,
              content.displays.contains(where: { $0.frame.intersects(rect) }),
              let display = CaptureEngine.shared.display(containing: rect, in: content)
        else { return }
        finish(with: Selection(rect: rect, window: nil, display: display))
    }

    // MARK: Invalidation (global CG rects -> per-screen dirty rects)

    private func view(containing p: CGPoint) -> SelectionOverlayView? {
        views.first { $0.screenFrameCG.contains(p) }
    }

    private func invalidate(cg rect: CGRect?) {
        guard let rect else { return }
        let r = rect.insetBy(dx: -3, dy: -3)   // covers the 2pt hover stroke
        for v in views where v.screenFrameCG.intersects(r) {
            v.setNeedsDisplay(v.viewRect(fromCG: r))
        }
    }

    private func invalidateCursorChrome(at p: CGPoint) {
        guard let v = view(containing: p) else { return }
        let local = v.viewPoint(fromCG: p)
        v.setNeedsDisplay(NSRect(x: local.x - 1, y: 0, width: 2, height: v.bounds.height))
        v.setNeedsDisplay(NSRect(x: 0, y: local.y - 1, width: v.bounds.width, height: 2))
    }

    private func invalidateSelection(from old: CGRect, to new: CGRect) {
        // Inflated so the size pill hanging off the bottom-right is covered.
        invalidate(cg: old.union(new).insetBy(dx: -130, dy: -60))
    }
}

// MARK: - Overlay panel

/// Borderless, non-activating, key-capable, one per screen. Level and
/// collection behaviour follow the CleanShot-class overlay recipe.
@MainActor
private final class SelectionOverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    // Borderless panels refuse key status by default; Esc/Return need it.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay view

/// One per screen. Draws only content intersecting its own screen; the CG
/// global -> local flip happens here and nowhere else (flipped view + offset
/// by the screen's CG origin).
@MainActor
private final class SelectionOverlayView: NSView {
    private unowned let controller: SelectionController
    /// This screen's frame in global CG top-left points.
    let screenFrameCG: CGRect
    let displayID: CGDirectDisplayID
    /// Menu-bar strip height, so the hint pill sits below it, not across it.
    private let topInset: CGFloat

    init(screen: NSScreen, controller: SelectionController) {
        self.controller = controller
        self.screenFrameCG = Coords.cgRect(fromAppKit: screen.frame)
        self.displayID = screen.displayID
        self.topInset = screen.frame.maxY - screen.visibleFrame.maxY
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) {
        fatalError("SelectionOverlayView does not support init(coder:)")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // The first click on a non-key panel must register, not merely focus it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // .activeAlways: mouse-moved must arrive on every screen's panel, not
        // just the key one.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Coordinate flip

    func viewRect(fromCG r: CGRect) -> NSRect {
        r.offsetBy(dx: -screenFrameCG.minX, dy: -screenFrameCG.minY)
    }

    func viewPoint(fromCG p: CGPoint) -> NSPoint {
        NSPoint(x: p.x - screenFrameCG.minX, y: p.y - screenFrameCG.minY)
    }

    private func cgPoint(from event: NSEvent) -> CGPoint {
        guard let window else {
            return Coords.cgPoint(fromAppKit: NSEvent.mouseLocation)
        }
        return Coords.cgPoint(fromAppKit: window.convertPoint(toScreen: event.locationInWindow))
    }

    func invalidateHintArea() {
        setNeedsDisplay(NSRect(x: bounds.midX - 320, y: 0, width: 640, height: topInset + 64))
    }

    // MARK: Events -> controller

    override func mouseMoved(with event: NSEvent) {
        controller.handleMouseMoved(to: cgPoint(from: event))
    }

    override func mouseDown(with event: NSEvent) {
        controller.handleMouseDown(at: cgPoint(from: event), on: self)
    }

    override func mouseDragged(with event: NSEvent) {
        controller.handleMouseDragged(
            to: cgPoint(from: event),
            shift: event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        controller.handleMouseUp(at: cgPoint(from: event))
    }

    // No super calls below: unhandled keys must not beep while the overlay is up.
    override func keyDown(with event: NSEvent) {
        controller.handleKeyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        controller.handleKeyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        controller.handleFlagsChanged(event.modifierFlags)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let selection: NSRect? = {
            guard controller.isDragging else { return nil }
            let cg = controller.currentDragRect()
            guard cg.width > 0, cg.height > 0, cg.intersects(screenFrameCG) else { return nil }
            return viewRect(fromCG: cg)
        }()

        // 25% dim with an even-odd hole punched over the live selection.
        let dim = NSBezierPath(rect: bounds)
        if let selection {
            dim.appendRect(selection)
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.25).setFill()
        dim.fill()

        if let selection {
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            border.stroke()
            drawSizeLabel(for: selection)
        }
        guard !controller.isDragging else { return }

        if let hover = controller.hoverWindow {
            let rect = viewRect(fromCG: hover.frame)
            if rect.intersects(bounds) {
                NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(rect: rect).fill()
                let stroke = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                stroke.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                stroke.stroke()
            }
        }

        if screenFrameCG.contains(controller.mouseCG) {
            drawCrosshair(at: viewPoint(fromCG: controller.mouseCG))
            drawHintPill()
        }
    }

    private func drawCrosshair(at p: NSPoint) {
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSRect(x: p.x - 0.5, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: p.y - 0.5, width: bounds.width, height: 1).fill()
    }

    private func drawSizeLabel(for selection: NSRect) {
        let text = String(format: "%.0f × %.0f", selection.width, selection.height)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pillSize = NSSize(width: textSize.width + 16, height: textSize.height + 8)
        var origin = NSPoint(x: selection.maxX - pillSize.width, y: selection.maxY + 6)
        if origin.y + pillSize.height > bounds.maxY - 4 {
            origin.y = selection.maxY - pillSize.height - 6   // no room below: tuck inside
        }
        origin.x = min(max(origin.x, 4), bounds.maxX - pillSize.width - 4)
        origin.y = min(max(origin.y, 4), bounds.maxY - pillSize.height - 4)
        drawPill(text: text, attrs: attrs, textSize: textSize,
                 in: NSRect(origin: origin, size: pillSize))
    }

    private func drawHintPill() {
        let text = controller.hintText
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pillSize = NSSize(width: textSize.width + 28, height: textSize.height + 12)
        drawPill(text: text, attrs: attrs, textSize: textSize, in: NSRect(
            x: (bounds.width - pillSize.width) / 2,
            y: topInset + 16,
            width: pillSize.width,
            height: pillSize.height))
    }

    private func drawPill(text: String, attrs: [NSAttributedString.Key: Any],
                          textSize: NSSize, in rect: NSRect) {
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.1).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        (text as NSString).draw(
            at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
            withAttributes: attrs)
    }
}
