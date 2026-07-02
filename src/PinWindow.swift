import AppKit

/// Pinned screenshots — borderless always-on-top panels the user can move,
/// resize from the corner, fade with the scroll wheel and act on via the
/// context menu.
@MainActor
final class PinController {
    static let shared = PinController()

    private var pins: [PinPanel] = []
    private(set) var allHidden = false

    var hasPins: Bool { !pins.isEmpty }

    /// One keystroke to sweep every pin out of the way and back.
    func toggleAllHidden() {
        allHidden.toggle()
        for pin in pins {
            if allHidden { pin.orderOut(nil) } else { pin.orderFrontRegardless() }
        }
    }

    private init() {}

    func pin(_ still: StillCapture) {
        allHidden = false
        let panel = PinPanel(still: still)
        pins.append(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func closeAll() {
        for panel in Array(pins) {
            panel.fadeOutAndClose()
        }
    }

    fileprivate func pinDidClose(_ panel: PinPanel) {
        pins.removeAll { $0 === panel }
    }
}

@MainActor
private func pinScreenUnderMouse() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        ?? NSScreen.main
        ?? NSScreen.screens.first
}

// MARK: - Panel

@MainActor
private final class PinPanel: NSPanel {
    // Borderless panels refuse key by default; key is needed for Cmd-W.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(still: StillCapture) {
        let frame = PinPanel.initialFrame(for: still)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = PinContentView(still: still)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            fadeOutAndClose()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func fadeOutAndClose() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            self.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.orderOut(nil)
                PinController.shared.pinDidClose(self)
            }
        })
    }

    /// Exactly over the captured region when known and it fits; otherwise
    /// capped to 80% of the screen and centred (over the region, or on the
    /// mouse's screen for composites).
    private static func initialFrame(for still: StillCapture) -> NSRect {
        let overRect = still.screenRect.map { Coords.appKitRect(fromCG: $0) }
        let screen = overRect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? pinScreenUnderMouse()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var size = still.pointSize
        let cap = min(1, visible.width * 0.8 / max(size.width, 1), visible.height * 0.8 / max(size.height, 1))
        if cap < 1 {
            size = NSSize(width: size.width * cap, height: size.height * cap)
        }
        if let overRect {
            if cap >= 1 { return overRect }
            return NSRect(
                x: overRect.midX - size.width / 2, y: overRect.midY - size.height / 2,
                width: size.width, height: size.height)
        }
        return NSRect(
            x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
            width: size.width, height: size.height)
    }
}

// MARK: - Content

@MainActor
private final class PinContentView: NSView {
    private let still: StillCapture
    private let closeButton = PinCloseButton()
    private let resizeHandle: PinResizeHandle

    init(still: StillCapture) {
        self.still = still
        let size = still.pointSize
        resizeHandle = PinResizeHandle(aspect: size.height > 0 ? size.width / size.height : 1)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        let imageView = PinStaticImageView(frame: bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = NSImage(cgImage: still.image, size: size)
        addSubview(imageView)

        closeButton.frame = NSRect(x: 6, y: bounds.height - 26, width: 20, height: 20)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.alphaValue = 0
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        addSubview(closeButton)

        resizeHandle.frame = NSRect(x: bounds.width - 16, y: 0, width: 16, height: 16)
        resizeHandle.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(resizeHandle)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // becomesKeyOnlyIfNeeded panels only take key when a clicked view asks —
    // without this, Cmd-W never reaches the panel and closes the frontmost
    // app's window instead.
    override var needsPanelToBecomeKey: Bool { true }

    // MARK: Hover

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ hovering: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            closeButton.animator().alphaValue = hovering ? 1 : 0
        }
        layer?.borderWidth = hovering ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
    }

    // MARK: Scroll = opacity

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.004 : 0.04
        let alpha = window.alphaValue + event.scrollingDeltaY * step
        window.alphaValue = min(1.0, max(0.2, alpha))
    }

    // MARK: Context menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector) {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        add("Copy", #selector(copyAction))
        add("Save", #selector(saveAction))
        add("Annotate", #selector(annotateAction))
        menu.addItem(.separator())
        add("Close", #selector(closeAction))
        add("Close All Pins", #selector(closeAllAction))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Actions

    @objc private func copyAction() {
        OutputRouter.shared.copyToClipboard(still)
        Toast.show("Copied", symbol: "doc.on.doc")
    }

    @objc private func saveAction() {
        if OutputRouter.shared.reExport(still) != nil {
            Toast.show("Saved", symbol: "arrow.down.circle")
        }
    }

    @objc private func annotateAction() {
        OutputRouter.shared.openAnnotator(still)
        (window as? PinPanel)?.fadeOutAndClose()
    }

    @objc private func closeAction() {
        (window as? PinPanel)?.fadeOutAndClose()
    }

    @objc private func closeAllAction() {
        PinController.shared.closeAll()
    }
}

private final class PinStaticImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Chrome

private final class PinCloseButton: NSButton {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(config)
        contentTintColor = .white
        toolTip = "Close"
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Faded out it must not swallow the drag-to-move click in that corner.
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0.5 ? super.hitTest(point) : nil
    }
}

/// Invisible 16pt grab region in the bottom-right corner; drags resize the
/// panel with the image's aspect locked.
private final class PinResizeHandle: NSView {
    private let aspect: CGFloat
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    init(aspect: CGFloat) {
        self.aspect = max(aspect, 0.01)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        // The handle is geometrically bottom-right regardless of layout direction.
        NSCursor.frameResize(position: .bottomRight, directions: .all).set()
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, startFrame.width > 0 else { return }
        let mouse = NSEvent.mouseLocation
        // Follow whichever axis the drag pushes further; the top-left corner
        // stays anchored so growth heads toward the drag.
        let byWidth = startFrame.width + (mouse.x - startMouse.x)
        let byHeight = (startFrame.height + (startMouse.y - mouse.y)) * aspect
        let width = max(80, max(byWidth, byHeight))
        let height = width / aspect
        window.setFrame(
            NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height),
            display: true)
    }

    override func mouseUp(with event: NSEvent) {
        window?.invalidateShadow()
    }
}
