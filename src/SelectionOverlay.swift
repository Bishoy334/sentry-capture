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

    enum Mode { case still, window, record, scrolling, ocr, pin, allInOne, measure }

    struct Selection {
        var rect: CGRect        // global CG top-left-origin points
        let window: SCWindow?   // non-nil when the user picked a window
        let display: SCDisplay  // the display containing the selection
        /// Full-display capture taken when the overlay froze the screen —
        /// area captures crop this instead of re-shooting, so what the user
        /// selected (hover states, open menus) is exactly what they get.
        var frozen: StillCapture? = nil
        /// All-in-One only: which action the user picked from the strip.
        var chosenAction: HotkeyAction? = nil
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
    /// Frozen full-display captures, keyed by display id; taken BEFORE the
    /// panels show, so they never need self-exclusion.
    private var frozen: [CGDirectDisplayID: StillCapture] = [:]
    fileprivate var frozenImages: [CGDirectDisplayID: NSImage] = [:]
    fileprivate var heldRect: CGRect? { heldSelection?.rect }
    fileprivate var mouseCG: CGPoint = .zero
    fileprivate var hoverWindow: SCWindow?
    fileprivate var isDragging = false

    private var dragPending = false
    /// All-in-One: a completed selection held on screen while the user picks
    /// an action from the strip.
    private var heldSelection: Selection?
    /// A drag that started on the held selection: inside slides it, on a
    /// handle resizes it. Resizes work from the gesture-original rect so
    /// dragging past the opposite edge can't collapse the rect.
    private enum HeldDrag {
        case move(last: CGPoint)
        case resize(handle: SelectionHandle, original: CGRect, down: CGPoint)
    }
    private var heldDrag: HeldDrag?
    private var strip: AllInOneStrip?
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
        case .still, .window, .record, .allInOne: return true
        case .scrolling, .ocr, .pin, .measure: return false
        }
    }

    /// Freezing suits point-in-time captures; live flows (recording,
    /// scrolling) must keep showing the real screen.
    private var freezeAllowed: Bool {
        switch mode {
        case .still, .window, .ocr, .pin, .allInOne: return Settings.shared.freezeSelectionScreen
        case .measure: return true   // stable pixels while measuring
        case .record, .scrolling: return false
        }
    }

    fileprivate var hintText: String {
        switch mode {
        case .still, .record: return "Drag to select — click a window — Esc cancels"
        case .window: return "Click a window — drag to select — Esc cancels"
        case .ocr: return "Drag over text — Esc cancels"
        case .scrolling, .pin: return "Drag to select — Esc cancels"
        case .allInOne: return "Select, then pick an action below — Esc cancels"
        case .measure: return "Drag to measure — Esc cancels"
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
                if self.freezeAllowed {
                    for display in fetched.displays {
                        guard let still = try? await CaptureEngine.shared.captureDisplay(display),
                              self.isActive, self.generation == gen else { continue }
                        self.frozen[display.displayID] = still
                        self.frozenImages[display.displayID] = NSImage(
                            cgImage: still.image, size: still.pointSize)
                    }
                    guard self.isActive, self.generation == gen else { return }
                }
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

        if mode == .allInOne {
            let mouseScreen = screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? screens[0]
            let strip = AllInOneStrip(screen: mouseScreen) { [weak self] action in
                self?.stripPicked(action)
            }
            strip.onSizeChange = { [weak self] width, height in
                self?.resizeHeld(width: width, height: height)
            }
            strip.onEditingEnded = { [weak self] in
                // Hand key back to the overlay so Esc/Return work again.
                guard let self else { return }
                let held = self.heldSelection?.rect
                let target = zip(self.panels, self.views)
                    .first { held.map($0.1.screenFrameCG.intersects) ?? false }?.0
                (target ?? self.panels.first)?.makeKeyAndOrderFront(nil)
            }
            strip.setSelectionAvailable(false)
            strip.orderFrontRegardless()
            self.strip = strip
        }
    }

    // MARK: All-in-One

    private func stripPicked(_ action: HotkeyAction?) {
        guard isActive else { return }
        guard let action else {
            finish(with: nil)   // strip cancel button
            return
        }
        if action == .captureFullscreen {
            // Whole display of the held selection (or the mouse), routed as a
            // plain area so the frozen-crop path applies.
            let display = heldSelection?.display
                ?? content?.displays.first { $0.frame.contains(mouseCG) }
                ?? content?.displays.first
            guard let display else { return }
            var selection = Selection(
                rect: display.frame, window: nil, display: display,
                frozen: frozen[display.displayID])
            selection.chosenAction = .captureArea
            finish(with: selection)
            return
        }
        guard var selection = heldSelection else { return }
        selection.chosenAction = action
        finish(with: selection)
    }

    private func hold(_ selection: Selection) {
        let old = heldSelection?.rect
        heldSelection = selection
        invalidate(cg: old)
        invalidateSelection(from: selection.rect, to: selection.rect)
        strip?.setSelectionAvailable(true)
        strip?.setSize(selection.rect.size)
        for v in views { v.invalidateHintArea() }
    }

    private func clearHeld() {
        guard let held = heldSelection else { return }
        heldSelection = nil
        heldDrag = nil
        strip?.setSelectionAvailable(false)
        strip?.setSize(nil)
        invalidateSelection(from: held.rect, to: held.rect)
        resetToIdle(at: mouseCG)
    }

    /// Exact-size entry from the strip: resizes the held selection anchored
    /// at its top-left, clamped to its display.
    private func resizeHeld(width: CGFloat?, height: CGFloat?) {
        guard var held = heldSelection else { return }
        let f = held.display.frame
        let old = held.rect
        var r = old
        if let width { r.size.width = min(max(width, 10), f.maxX - r.minX) }
        if let height { r.size.height = min(max(height, 10), f.maxY - r.minY) }
        held.rect = r
        heldSelection = held
        invalidateSelection(from: old, to: r)
        strip?.setSize(r.size)
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
        strip?.orderOut(nil)
        strip = nil
        heldSelection = nil
        heldDrag = nil

        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }

        content = nil
        frozen.removeAll()
        frozenImages.removeAll()
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
        let newHover = (isDragging || heldSelection != nil) ? nil : windowUnder(mouseCG)
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
        if let held = heldSelection {
            // On a handle resizes, inside slides, outside starts over.
            if let handle = SelectionHandle.hit(p, rect: held.rect) {
                heldDrag = .resize(handle: handle, original: held.rect, down: p)
                return
            }
            if held.rect.contains(p) {
                heldDrag = .move(last: p)
                return
            }
        }
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
        guard isActive else { return }
        if let drag = heldDrag, var held = heldSelection {
            let f = held.display.frame
            let old = held.rect
            switch drag {
            case .move(let last):
                var dx = p.x - last.x
                var dy = p.y - last.y
                dx = min(max(dx, f.minX - held.rect.minX), f.maxX - held.rect.maxX)
                dy = min(max(dy, f.minY - held.rect.minY), f.maxY - held.rect.maxY)
                held.rect = held.rect.offsetBy(dx: dx, dy: dy)
                heldDrag = .move(last: p)
            case .resize(let handle, let original, let down):
                held.rect = handle.resized(
                    original, dx: p.x - down.x, dy: p.y - down.y, within: f)
            }
            heldSelection = held
            invalidateSelection(from: old, to: held.rect)
            strip?.setSize(held.rect.size)
            return
        }
        guard dragPending || isDragging else { return }
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
        if heldDrag != nil {
            heldDrag = nil
            return
        }
        if isDragging {
            let rect = currentDragRect()
            if rect.width >= 4, rect.height >= 4,
               let display = dragDisplay
                   ?? content.flatMap({ CaptureEngine.shared.display(containing: rect, in: $0) }) {
                let selection = Selection(
                    rect: rect, window: nil, display: display,
                    frozen: frozen[display.displayID])
                if mode == .allInOne {
                    isDragging = false
                    hold(selection)
                } else {
                    finish(with: selection)
                }
            } else {
                resetToIdle(at: p)
            }
        } else if heldSelection == nil,
                  windowPickAllowed,
                  let picked = hoverWindow ?? windowUnder(p),
                  let content,
                  let display = CaptureEngine.shared.display(containing: picked.frame, in: content) {
            let selection = Selection(rect: picked.frame, window: picked, display: display)
            if mode == .allInOne {
                hold(selection)
            } else {
                finish(with: selection)
            }
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
            if heldSelection != nil {
                clearHeld()
            } else {
                finish(with: nil)
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mode == .allInOne, heldSelection != nil {
                stripPicked(.captureArea)   // Return = the default action
            } else {
                repeatLastArea()
            }
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
        let selection = Selection(
            rect: rect, window: nil, display: display, frozen: frozen[display.displayID])
        if mode == .allInOne {
            hold(selection)
        } else {
            finish(with: selection)
        }
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

    fileprivate func frozenStill(for displayID: CGDirectDisplayID) -> StillCapture? {
        frozen[displayID]
    }

    private func invalidateCursorChrome(at p: CGPoint) {
        guard let v = view(containing: p) else { return }
        let local = v.viewPoint(fromCG: p)
        v.setNeedsDisplay(NSRect(x: local.x - 1, y: 0, width: 2, height: v.bounds.height))
        v.setNeedsDisplay(NSRect(x: 0, y: local.y - 1, width: v.bounds.width, height: 2))
        // The loupe floats within ~140pt of the cursor on any side.
        v.setNeedsDisplay(NSRect(x: local.x - 160, y: local.y - 160, width: 320, height: 320))
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
        // The frozen frame replaces the live screen underneath the dim — the
        // user keeps "seeing the screen", but it can no longer change under
        // the selection (and the loupe has stable pixels to magnify).
        if let frozenImage = controller.frozenImages[displayID] {
            frozenImage.draw(
                in: bounds, from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: 1)])
        }
        let selection: NSRect? = {
            let cg: CGRect
            if controller.isDragging {
                cg = controller.currentDragRect()
            } else if let held = controller.heldRect {
                cg = held
            } else {
                return nil
            }
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
            if !controller.isDragging, controller.heldRect != nil {
                drawResizeHandles(for: selection)
            }
        }
        guard !controller.isDragging, controller.heldRect == nil else { return }

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
            drawLoupe(at: viewPoint(fromCG: controller.mouseCG))
            drawHintPill()
        }
    }

    /// Pixel loupe: 6x magnification of the frozen frame around the cursor,
    /// with a centre tick and the cursor's point coordinates.
    private func drawLoupe(at p: NSPoint) {
        guard let still = controller.frozenStill(for: displayID) else { return }
        let size: CGFloat = 110
        let magnification: CGFloat = 6
        var origin = NSPoint(x: p.x + 22, y: p.y + 22)
        if origin.x + size > bounds.maxX - 8 { origin.x = p.x - size - 22 }
        if origin.y + size + 22 > bounds.maxY - 8 { origin.y = p.y - size - 22 }
        let rect = NSRect(x: origin.x, y: origin.y, width: size, height: size)

        let sourceSide = size / magnification
        let scale = still.scale
        let pxHeight = CGFloat(still.image.height)
        // View point -> top-left pixel coords -> bottom-left image space.
        let cx = p.x * scale
        let cyTL = p.y * scale
        let half = sourceSide * scale / 2
        let source = NSRect(
            x: cx - half, y: pxHeight - cyTL - half,
            width: sourceSide * scale, height: sourceSide * scale)

        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(ovalIn: rect)
        clip.addClip()
        let image = controller.frozenImages[displayID]
        // NSImage size is in points; from-rect is in the image's own space.
        image?.draw(
            in: rect,
            from: NSRect(
                x: source.minX / scale, y: source.minY / scale,
                width: source.width / scale, height: source.height / scale),
            operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: [.interpolation: NSNumber(value: 1)])
        NSGraphicsContext.restoreGraphicsState()

        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.9).setStroke()
        ring.stroke()
        // Centre tick: the pixel under the cursor.
        let tick = NSRect(
            x: rect.midX - magnification / scale / 2,
            y: rect.midY - magnification / scale / 2,
            width: magnification / scale * 2, height: magnification / scale * 2)
        NSColor.controlAccentColor.setStroke()
        NSBezierPath(rect: tick).stroke()

        let coords = String(
            format: "%.0f, %.0f", controller.mouseCG.x, controller.mouseCG.y)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (coords as NSString).size(withAttributes: attrs)
        drawPill(text: coords, attrs: attrs, textSize: textSize, in: NSRect(
            x: rect.midX - (textSize.width + 12) / 2, y: rect.maxY + 4,
            width: textSize.width + 12, height: textSize.height + 6))
    }

    private func drawResizeHandles(for selection: NSRect) {
        let side: CGFloat = 7
        for handle in SelectionHandle.allCases {
            let c = handle.point(in: selection)
            let rect = NSRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
            NSColor.white.setFill()
            NSBezierPath(rect: rect).fill()
            let stroke = NSBezierPath(rect: rect)
            stroke.lineWidth = 1
            NSColor.controlAccentColor.setStroke()
            stroke.stroke()
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


// MARK: - Held-selection resize handles

/// The eight resize handles on a held All-in-One selection, in global CG
/// top-left space (top = minY edge).
enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    func point(in r: CGRect) -> CGPoint {
        let x = movesLeft ? r.minX : (movesRight ? r.maxX : r.midX)
        let y = movesTop ? r.minY : (movesBottom ? r.maxY : r.midY)
        return CGPoint(x: x, y: y)
    }

    static func hit(_ p: CGPoint, rect: CGRect, radius: CGFloat = 8) -> SelectionHandle? {
        allCases
            .map { (handle: $0, d: hypot(p.x - $0.point(in: rect).x, p.y - $0.point(in: rect).y)) }
            .filter { $0.d <= radius }
            .min { $0.d < $1.d }?
            .handle
    }

    /// New rect from the gesture-original rect with this handle's edges moved
    /// by the drag delta, clamped to the display and a 10pt minimum side.
    func resized(_ original: CGRect, dx: CGFloat, dy: CGFloat, within f: CGRect) -> CGRect {
        var minX = original.minX, minY = original.minY
        var maxX = original.maxX, maxY = original.maxY
        if movesLeft { minX = min(max(f.minX, original.minX + dx), maxX - 10) }
        if movesRight { maxX = max(min(f.maxX, original.maxX + dx), minX + 10) }
        if movesTop { minY = min(max(f.minY, original.minY + dy), maxY - 10) }
        if movesBottom { maxY = max(min(f.maxY, original.maxY + dy), minY + 10) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - All-in-One action strip

/// Floating action bar for All-in-One mode: pick what happens to the held
/// selection. Non-activating so the frontmost app keeps focus; sits above the
/// overlay panels at the same level by ordering after them.
@MainActor
private final class AllInOneStrip: NSPanel, NSTextFieldDelegate {
    private let onPick: (HotkeyAction?) -> Void
    /// Exact-size entry commits: (width, height) — nil leaves that axis alone.
    var onSizeChange: ((CGFloat?, CGFloat?) -> Void)?
    /// Fired when field editing ends so the overlay can take key back.
    var onEditingEnded: (() -> Void)?
    private var selectionButtons: [NSButton] = []
    private var captureButton: NSButton?
    private var widthField: NSTextField!
    private var heightField: NSTextField!

    init(screen: NSScreen, onPick: @escaping (HotkeyAction?) -> Void) {
        self.onPick = onPick
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true

        let entries: [(symbol: String, label: String, action: HotkeyAction?, needsSelection: Bool)] = [
            ("camera.viewfinder", "Capture", .captureArea, true),
            ("display", "Fullscreen", .captureFullscreen, false),
            ("record.circle", "Record", .recordVideo, true),
            ("photo.stack", "GIF", .recordGIF, true),
            ("arrow.up.and.down.square", "Scrolling", .scrollingCapture, true),
            ("text.viewfinder", "OCR", .copyText, true),
            ("pin", "Pin", .pinArea, true),
        ]

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        // Exact-size entry: type a width/height, Return commits.
        widthField = sizeField(placeholder: "W")
        heightField = sizeField(placeholder: "H")
        let xLabel = NSTextField(labelWithString: "×")
        xLabel.font = .systemFont(ofSize: 11, weight: .medium)
        xLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        stack.addArrangedSubview(widthField)
        stack.addArrangedSubview(xLabel)
        stack.addArrangedSubview(heightField)
        stack.addArrangedSubview(stripDivider())
        stack.setCustomSpacing(4, after: widthField)
        stack.setCustomSpacing(4, after: xLabel)
        stack.setCustomSpacing(8, after: heightField)
        stack.setCustomSpacing(8, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])

        for (i, entry) in entries.enumerated() {
            let button = stripButton(symbol: entry.symbol, label: entry.label, tag: i)
            stack.addArrangedSubview(button)
            if entry.needsSelection { selectionButtons.append(button) }
            if entry.action == .captureArea {
                button.toolTip = "\(entry.label) (⏎)"
                captureButton = button
            }
        }
        let divider = stripDivider()
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(8, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        stack.setCustomSpacing(8, after: divider)
        let cancel = stripButton(symbol: "xmark", label: "Cancel", tag: entries.count)
        cancel.toolTip = "Cancel (Esc)"
        stack.addArrangedSubview(cancel)
        self.entriesActions = entries.map(\.action)

        let card = HUDStyle.card()
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        contentView = card

        let size = stack.fittingSize
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 28)
        setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private var entriesActions: [HotkeyAction?] = []

    private func stripDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return divider
    }

    private func sizeField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .center
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.isEnabled = false
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        return field
    }

    /// Reflect the held selection's size; nil disables the fields (no selection).
    func setSize(_ size: CGSize?) {
        for (field, value) in [(widthField, size?.width), (heightField, size?.height)] {
            guard let field else { continue }
            field.isEnabled = value != nil
            // Never fight the user's in-progress typing.
            if field.currentEditor() == nil {
                field.stringValue = value.map { String(Int($0.rounded())) } ?? ""
            }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if let value = Double(field.stringValue), value > 0 {
            onSizeChange?(
                field === widthField ? CGFloat(value) : nil,
                field === heightField ? CGFloat(value) : nil)
        }
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        if movement == NSTextMovement.return.rawValue {
            makeFirstResponder(nil)
            onEditingEnded?()
        }
    }

    /// Esc while editing must not close the strip (NSPanel's default cancel).
    override func cancelOperation(_ sender: Any?) {
        makeFirstResponder(nil)
        onEditingEnded?()
    }

    private func stripButton(symbol: String, label: String, tag: Int) -> NSButton {
        let button = StripHoverButton()
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageAbove
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        button.title = label
        button.font = .systemFont(ofSize: 9.5, weight: .medium)
        button.alignment = .center   // imageAbove keeps natural (left) title alignment otherwise
        button.contentTintColor = .white
        button.toolTip = label
        button.tag = tag
        button.target = self
        button.action = #selector(buttonTapped(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 62).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    func setSelectionAvailable(_ available: Bool) {
        for button in selectionButtons {
            button.isEnabled = available
            button.alphaValue = available ? 1 : 0.35
        }
        // Capture is the strip's default action (Return) — read as primary.
        captureButton?.contentTintColor = available ? .controlAccentColor : .white
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        if sender.tag < entriesActions.count {
            onPick(entriesActions[sender.tag])
        } else {
            onPick(nil)   // cancel
        }
    }

    // Key-capable for the size fields; becomesKeyOnlyIfNeeded means only a
    // field click takes key — the action buttons never steal it.
    override var canBecomeKey: Bool { true }
}

/// Strip button with a soft hover wash — plain glyph rows read as labels
/// until something responds to the pointer.
@MainActor
private final class StripHoverButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}
