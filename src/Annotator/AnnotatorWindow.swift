import AppKit
import UniformTypeIdentifiers

// MARK: - Controller (public contract)

@MainActor
final class AnnotatorController {
    static let shared = AnnotatorController()

    private var editors: [AnnotatorWindowController] = []

    private init() {}

    /// One editor window per capture; multiple may be open at once. When the
    /// capture's record carries a .sentryshot project, the clean base and the
    /// live annotation objects are restored instead of the baked media.
    func open(_ still: StillCapture) {
        guard still.image.width > 0, still.image.height > 0 else {
            Toast.show("Nothing to annotate", symbol: "exclamationmark.triangle")
            return
        }
        var editorStill = still
        var restored: [AnnotatorAnnotation] = []
        var restoredBackground: AnnotatorBackgroundStyle?
        if let id = still.recordID,
           SentryStore.shared.loadManifest(for: id)?.annotations?.project != nil,
           let project = AnnotatorProject.load(from: SentryStore.shared.recordDirectory(for: id)) {
            editorStill = StillCapture(
                image: project.baseImage, scale: project.scale, source: still.source,
                screenRect: nil, origin: still.origin, recordID: id)
            restored = project.annotations
            restoredBackground = project.background
        }
        let editor = AnnotatorWindowController(
            still: editorStill, restoredAnnotations: restored,
            restoredBackground: restoredBackground)
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
        }
        editors.append(editor)
        editor.show()
    }
}

// MARK: - Window

/// Routes key equivalents and bare-letter tool keys to the controller before
/// AppKit sees them — the app has no main menu to supply key equivalents.
private final class AnnotatorEditorWindow: NSWindow {
    weak var keyHandler: AnnotatorWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - Per-window controller

@MainActor
final class AnnotatorWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let window: NSWindow
    private let canvas: AnnotatorCanvas
    private let scrollView = NSScrollView()
    private let source: StillSource
    private let origin: CaptureOrigin?
    private let recordID: String?
    private let windowUndoManager = UndoManager()

    private var toolButtons: [(tool: AnnotatorTool, button: NSButton)] = []
    private let optionsStack = NSStackView()
    private var optionsBarHeight: NSLayoutConstraint!
    private let sidebarStack = NSStackView()
    private var sidebarWidth: NSLayoutConstraint!
    private let inspectorStack = NSStackView()
    private var inspectorWidth: NSLayoutConstraint!
    private var adjustButton: NSButton?
    private var adjustActive = false
    private var adjustSliders: [NSSlider] = []
    private var adjustResets: [NSButton] = []
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let dimensionsLabel = NSTextField(labelWithString: "")
    /// Each tool remembers its own colour/width, CleanShot-style — switching
    /// from a red arrow to the highlighter must not paint red highlights.
    private var toolColours: [AnnotatorTool: NSColor] = [:]
    private var toolWidths: [AnnotatorTool: CGFloat] = [:]
    private let backdrop = AnnotatorBackdropView()
    private var backgroundButton: NSButton?
    private var backgroundBarActive = false
    private var backgroundStyle = AnnotatorBackgroundStyle() {
        didSet {
            layoutBackdrop()
            refreshChrome()
            // Padding growth must not push the document out of view.
            zoomOutToFitIfNeeded()
        }
    }

    /// Toolbar layout: capture-level, shapes, emphasis, ink, then select.
    /// nil entries render as group separators.
    private static let toolbarGroups: [[AnnotatorTool]] = [
        [.crop, .lift],
        [.arrow, .line, .rect, .filledRect, .ellipse],
        [.highlighter, .redact, .spotlight, .counter],
        [.draw, .text],
        [.select],
    ]

    private static let palette: [(colour: NSColor, name: String)] = [
        (.systemRed, "Red"), (.systemOrange, "Orange"), (.systemYellow, "Yellow"),
        (.systemGreen, "Green"), (.systemBlue, "Blue"), (.systemPurple, "Purple"),
        (.black, "Black"), (.white, "White"),
    ]
    private static let strokeWidths: [CGFloat] = [2, 4, 6]
    private static let textSizes: [(label: String, size: CGFloat)] = [("S", 14), ("M", 20), ("L", 28)]
    private static let cropAspects: [(label: String, ratio: CGFloat?)] = [
        ("Free", nil), ("1:1", 1), ("16:9", 16.0 / 9.0), ("4:3", 4.0 / 3.0), ("3:2", 3.0 / 2.0),
    ]

    init(
        still: StillCapture,
        restoredAnnotations: [AnnotatorAnnotation] = [],
        restoredBackground: AnnotatorBackgroundStyle? = nil
    ) {
        source = still.source
        origin = still.origin
        recordID = still.recordID
        canvas = AnnotatorCanvas(still: still)
        if !restoredAnnotations.isEmpty {
            canvas.restoreAnnotations(restoredAnnotations)
        }
        let editorWindow = AnnotatorEditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window = editorWindow
        super.init()

        editorWindow.keyHandler = self
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.tabbingMode = .disallowed
        // Sentry chrome (matches sentry-finder): committed dark, transparent
        // titlebar over a tinted behind-window blur — native controls pick up
        // the dark translucent look from the appearance, not custom drawing.
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = HUDStyle.editorTint
        window.contentView = buildContent()

        canvas.onStateChange = { [weak self] in self?.refreshChrome() }
        canvas.onImageChanged = { [weak self] in
            self?.refreshImageMeta()
            self?.layoutBackdrop()
        }
        canvas.onCanvasResized = { [weak self] in
            self?.layoutBackdrop()
            // Merging images / spilling annotations grows the canvas — zoom
            // out so the whole document stays in view.
            self?.zoomOutToFitIfNeeded()
        }
        canvas.onAdjustmentsBaked = { [weak self] in
            self?.syncAdjustInspector()
            self?.refreshChrome()
        }

        sizeWindowToImage()
        refreshImageMeta()
        refreshChrome()
        if let restoredBackground {
            backgroundStyle = restoredBackground
        }
    }

    func show() {
        AppActivation.acquire()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // The shared colour panel outlives the editor — don't leave it
        // pointing at a dead target (no public getter, so clear it blind).
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.close()
        }
        AppActivation.release()
        onClose?()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        windowUndoManager
    }

    // MARK: Layout

    private func buildContent() -> NSView {
        let content = HUDStyle.tintedBlurCanvas()

        let toolbar = buildToolbar()
        let optionsBar = buildOptionsBar()
        let sidebar = buildBackgroundSidebar()
        let inspector = buildAdjustInspector()
        let footer = buildFooter()

        backdrop.addSubview(canvas)
        scrollView.documentView = backdrop
        layoutBackdrop()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 4
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        // Breathing room around the document — the image floating on the
        // surround reads as "a thing being edited", not a filled window.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshZoomLabel() }
        }

        for v in [toolbar, optionsBar, sidebar, inspector, scrollView, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 0)
        inspectorWidth = inspector.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            optionsBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            optionsBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            optionsBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),

            // Background workspace column — zero width until toggled on.
            sidebarWidth,
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: footer.topAnchor),

            // Adjustments inspector — right-hand column, zero width until toggled.
            inspectorWidth,
            inspector.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
            inspector.bottomAnchor.constraint(equalTo: footer.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),
        ])
        return content
    }

    private func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = HUDStyle.hairline.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }

    private func buildToolbar() -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (groupIndex, group) in Self.toolbarGroups.enumerated() {
            if groupIndex > 0 {
                let divider = hairline()
                divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(divider)
                stack.setCustomSpacing(8, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
                stack.setCustomSpacing(8, after: divider)
            }
            for tool in group {
                let index = AnnotatorTool.allCases.firstIndex(of: tool) ?? 0
                let button = toolbarIconButton(
                    symbol: tool.symbolName,
                    tooltip: "\(tool.label) (\(tool.key.uppercased()))",
                    action: #selector(toolTapped(_:)))
                button.tag = index
                stack.addArrangedSubview(button)
                toolButtons.append((tool, button))
            }
        }

        // Remove Background is an action, not a tool — it fires once and the
        // undo stack holds the result. Lives beside its sibling, lift.
        let removeBG = toolbarIconButton(
            symbol: "person.and.background.dotted", tooltip: "Remove Background",
            action: #selector(removeBackgroundTapped))
        stack.insertArrangedSubview(removeBG, at: 2)

        // Background mode is chrome-level, not a canvas tool — its button
        // lives beside crop but toggles the options bar instead of the tool.
        let background = toolbarIconButton(
            symbol: "photo.on.rectangle", tooltip: "Background (B)",
            action: #selector(backgroundTapped))
        stack.insertArrangedSubview(background, at: 3)
        backgroundButton = background

        // Adjustments inspector toggle — the right-hand column counterpart.
        let adjust = toolbarIconButton(
            symbol: "slider.horizontal.3", tooltip: "Adjust",
            action: #selector(adjustTapped))
        stack.insertArrangedSubview(adjust, at: 4)
        adjustButton = adjust

        // Sticker stamps: a one-tap emoji menu, placed as movable annotations.
        let sticker = toolbarIconButton(
            symbol: "face.smiling", tooltip: "Sticker",
            action: #selector(stickerTapped(_:)))
        stack.addArrangedSubview(sticker)

        // Undo/redo sit between the tools and the primary actions.
        undoButton = toolbarIconButton(
            symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)", action: #selector(undoTapped))
        redoButton = toolbarIconButton(
            symbol: "arrow.uturn.forward", tooltip: "Redo (⇧⌘Z)", action: #selector(redoTapped))

        // Primary actions live top-right: send, pin, copy, then a real Save
        // button — the terminal action of the whole editor, not another glyph.
        let send = toolbarIconButton(
            symbol: "paperplane", tooltip: "Send to Sentry app",
            action: #selector(sendToTapped(_:)))
        let pin = toolbarIconButton(
            symbol: "pin", tooltip: "Pin to Screen", action: #selector(pinTapped))
        let copy = toolbarIconButton(
            symbol: "doc.on.doc", tooltip: "Copy (⌘C)", action: #selector(copyTapped))
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.controlSize = .small
        save.font = .systemFont(ofSize: 12, weight: .medium)
        save.bezelColor = .controlAccentColor
        save.toolTip = "Save (⌘S)"
        let actions = NSStackView(views: [undoButton, redoButton, send, pin, copy, save])
        actions.orientation = .horizontal
        actions.spacing = 2
        actions.setCustomSpacing(12, after: redoButton)
        actions.setCustomSpacing(8, after: copy)
        actions.translatesAutoresizingMaskIntoConstraints = false

        let separator = hairline()
        container.addSubview(stack)
        container.addSubview(actions)
        container.addSubview(separator)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            actions.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    private func toolbarIconButton(
        symbol: String, tooltip: String, action: Selector
    ) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        button.toolTip = tooltip
        button.contentTintColor = .secondaryLabelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func buildOptionsBar() -> NSView {
        let container = NSView()
        optionsStack.orientation = .horizontal
        optionsStack.spacing = 8
        optionsStack.translatesAutoresizingMaskIntoConstraints = false

        let separator = hairline()
        container.addSubview(optionsStack)
        container.addSubview(separator)
        container.clipsToBounds = true   // collapsed bar must not bleed its separator
        optionsBarHeight = container.heightAnchor.constraint(equalToConstant: 34)
        NSLayoutConstraint.activate([
            optionsBarHeight,
            optionsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            optionsStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            optionsStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    private func buildFooter() -> NSView {
        let container = NSView()

        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimensionsLabel.textColor = .secondaryLabelColor

        func zoomButton(_ title: String, _ selector: Selector, tip: String) -> NSButton {
            let button = NSButton(title: title, target: self, action: selector)
            button.controlSize = .small
            button.bezelStyle = .accessoryBarAction
            button.font = .systemFont(ofSize: 11)
            button.toolTip = tip
            return button
        }
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let zoomOut = zoomButton("−", #selector(zoomOutTapped), tip: "Zoom out (⌘-)")
        let zoomIn = zoomButton("+", #selector(zoomInTapped), tip: "Zoom in (⌘+)")
        let zoomFit = zoomButton("Fit", #selector(zoomFitTapped), tip: "Fit in window")
        let zoomActual = zoomButton("100%", #selector(zoomActualTapped), tip: "Actual size (⌘0)")

        let saveAs = NSButton(title: "Save As…", target: self, action: #selector(saveAsTapped))
        saveAs.controlSize = .small
        saveAs.bezelStyle = .accessoryBarAction

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [
            dimensionsLabel, spacer, zoomOut, zoomLabel, zoomIn, zoomFit, zoomActual, saveAs,
        ])
        stack.setCustomSpacing(16, after: zoomActual)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let separator = hairline()
        container.addSubview(stack)
        container.addSubview(separator)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: container.topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    private func sizeWindowToImage() {
        let pt = canvas.pointSize
        // 48pt = the scroll view's content insets on both sides.
        var size = NSSize(width: pt.width + 48 + 2, height: pt.height + 48 + 44 + 34 + 30 + 2)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            size.width = min(size.width, screen.visibleFrame.width * 0.8)
            size.height = min(size.height, screen.visibleFrame.height * 0.8)
        }
        // Wide enough that the toolbar's tool groups and actions never collide.
        size.width = max(size.width, 720)
        size.height = max(size.height, 420)
        window.setContentSize(size)
        window.center()
    }

    // MARK: Chrome refresh

    private func refreshImageMeta() {
        let w = canvas.baseImage.width
        let h = canvas.baseImage.height
        window.title = "Annotate — \(w)x\(h)"
        dimensionsLabel.stringValue = "\(w) × \(h) px"
    }

    private func refreshChrome() {
        for (tool, button) in toolButtons {
            let selected = tool == canvas.tool
            button.layer?.backgroundColor = selected ? HUDStyle.accentDeep.cgColor : nil
            button.contentTintColor = selected ? .white : .secondaryLabelColor
        }
        undoButton.isEnabled = windowUndoManager.canUndo
        redoButton.isEnabled = windowUndoManager.canRedo
        if let backgroundButton {
            let active = backgroundBarActive || backgroundStyle.isVisible
            backgroundButton.layer?.backgroundColor =
                backgroundBarActive ? HUDStyle.accentDeep.cgColor : nil
            backgroundButton.contentTintColor = backgroundBarActive
                ? .white
                : (active ? HUDStyle.accent : .secondaryLabelColor)
        }
        if let adjustButton {
            // Amber hints that un-baked adjustments are live even with the
            // panel closed.
            let active = adjustActive || !canvas.adjustments.isIdentity
            adjustButton.layer?.backgroundColor =
                adjustActive ? HUDStyle.accentDeep.cgColor : nil
            adjustButton.contentTintColor = adjustActive
                ? .white
                : (active ? HUDStyle.accent : .secondaryLabelColor)
        }
        rebuildOptionsBar()
    }

    private func layoutBackdrop() {
        let pt = canvas.canvasPointSize
        let pad = backgroundStyle.isVisible ? backgroundStyle.padding : 0
        backdrop.style = backgroundStyle
        // A visible fill previews through transparent pixels (the canvas
        // suppresses its checker so the composition shows live).
        canvas.backdropFillVisible = backgroundStyle.isVisible
        backdrop.setFrameSize(NSSize(width: pt.width + pad * 2, height: pt.height + pad * 2))
        canvas.setFrameOrigin(NSPoint(x: pad, y: pad))
        canvas.setFrameSize(pt)
        // The preview rounds the live image the same way the export will.
        canvas.layer?.cornerRadius = backgroundStyle.isVisible ? backgroundStyle.cornerRadius : 0
        canvas.layer?.masksToBounds = backgroundStyle.isVisible
        backdrop.needsDisplay = true
    }

    /// Tracked-uppercase eyebrow, per the Sentry brand's section heads.
    private func eyebrow(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.8,
        ])
        return label
    }

    /// The adjustments workspace: a right column mirroring the background
    /// sidebar. Built once (controls update in place — rebuilding mid-drag
    /// would break a live slider); scrolls when the window is short.
    private func buildAdjustInspector() -> NSView {
        let container = NSView()
        container.clipsToBounds = true
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = AnnotatorFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        inspectorStack.orientation = .vertical
        inspectorStack.alignment = .leading
        inspectorStack.spacing = 8
        inspectorStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(inspectorStack)

        let edge = hairline()
        container.addSubview(scroll)
        container.addSubview(edge)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            inspectorStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 14),
            inspectorStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 14),
            inspectorStack.widthAnchor.constraint(equalToConstant: 162),
            doc.bottomAnchor.constraint(equalTo: inspectorStack.bottomAnchor, constant: 14),
            edge.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            edge.topAnchor.constraint(equalTo: container.topAnchor),
            edge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
        ])
        populateAdjustInspector()
        return container
    }

    private func populateAdjustInspector() {
        func action(_ title: String, _ selector: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: selector)
            button.controlSize = .small
            button.bezelStyle = .accessoryBarAction
            button.font = .systemFont(ofSize: 11)
            return button
        }
        let header = NSStackView(views: [
            action("Auto-Enhance", #selector(autoEnhanceTapped)),
            action("Reset", #selector(adjustResetAllTapped)),
        ])
        header.orientation = .horizontal
        header.spacing = 6
        inspectorStack.addArrangedSubview(header)

        var lastGroup = ""
        for p in AdjustParam.allCases {
            if p.group != lastGroup {
                lastGroup = p.group
                let head = eyebrow(p.group)
                inspectorStack.addArrangedSubview(head)
                inspectorStack.setCustomSpacing(4, after: head)
            }
            let label = NSTextField(labelWithString: p.label)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let reset = NSButton()
            reset.isBordered = false
            reset.setButtonType(.momentaryChange)
            reset.image = NSImage(
                systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset")?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
            reset.contentTintColor = .secondaryLabelColor
            reset.toolTip = "Reset \(p.label.lowercased())"
            reset.tag = p.rawValue
            reset.target = self
            reset.action = #selector(adjustResetTapped(_:))
            reset.isEnabled = false
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [label, spacer, reset])
            row.orientation = .horizontal
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 162).isActive = true

            let slider = NSSlider(
                value: p.range.neutral, minValue: p.range.min, maxValue: p.range.max,
                target: self, action: #selector(adjustChanged(_:)))
            slider.controlSize = .small
            slider.tag = p.rawValue
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 162).isActive = true

            inspectorStack.addArrangedSubview(row)
            inspectorStack.setCustomSpacing(0, after: row)
            inspectorStack.addArrangedSubview(slider)
            adjustSliders.append(slider)
            adjustResets.append(reset)
        }
    }

    /// Push the canvas's adjustment values back into the controls (panel
    /// open, bake, reset).
    private func syncAdjustInspector() {
        let a = canvas.adjustments
        for p in AdjustParam.allCases {
            adjustSliders[p.rawValue].doubleValue = Double(a[p])
            adjustResets[p.rawValue].isEnabled =
                abs(a[p] - CGFloat(p.range.neutral)) >= 0.0001
        }
    }

    /// The background workspace: a left column, not another toolbar row —
    /// fills, spacing and shadow live together like an inspector.
    private func buildBackgroundSidebar() -> NSView {
        let container = NSView()
        container.clipsToBounds = true
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 10
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebarStack)
        let edge = hairline()
        container.addSubview(edge)
        NSLayoutConstraint.activate([
            sidebarStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            sidebarStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            sidebarStack.widthAnchor.constraint(equalToConstant: 162),
            edge.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            edge.topAnchor.constraint(equalTo: container.topAnchor),
            edge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    private func rebuildBackgroundSidebar() {
        for view in sidebarStack.arrangedSubviews {
            view.removeFromSuperview()
        }

        func eyebrow(_ text: String) -> NSTextField {
            // Tracked-uppercase eyebrow, per the Sentry brand's section heads.
            let label = NSTextField(labelWithString: "")
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 0.8,
            ])
            return label
        }

        func fillSwatch(_ tag: Int, tooltip: String) -> NSButton {
            let button = NSButton()
            button.title = ""
            button.isBordered = false
            button.setButtonType(.momentaryChange)
            button.toolTip = tooltip
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor.separatorColor.cgColor
            button.tag = tag
            button.target = self
            button.action = #selector(backgroundFillTapped(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return button
        }

        // Tags: 0 none, 1... solids, 100... gradients.
        var swatches: [NSButton] = []
        let none = fillSwatch(0, tooltip: "No background")
        none.image = NSImage(
            systemSymbolName: "slash.circle", accessibilityDescription: "No background")
        none.contentTintColor = .secondaryLabelColor
        swatches.append(none)
        for (i, preset) in AnnotatorBackgroundStyle.solidPresets.enumerated() {
            let swatch = fillSwatch(1 + i, tooltip: preset.name)
            swatch.layer?.backgroundColor = preset.colour.cgColor
            swatches.append(swatch)
        }
        for (i, preset) in AnnotatorBackgroundStyle.gradientPresets.enumerated() {
            let swatch = fillSwatch(100 + i, tooltip: preset.name)
            let gradient = CAGradientLayer()
            gradient.frame = CGRect(x: 0, y: 0, width: 18, height: 18)
            gradient.cornerRadius = 9
            gradient.colors = preset.colours.map(\.cgColor)
            gradient.startPoint = CGPoint(x: 0, y: 1)
            gradient.endPoint = CGPoint(x: 1, y: 0)
            swatch.layer?.addSublayer(gradient)
            swatches.append(swatch)
        }

        sidebarStack.addArrangedSubview(eyebrow("FILL"))
        for chunk in stride(from: 0, to: swatches.count, by: 6) {
            let row = NSStackView(views: Array(swatches[chunk..<min(chunk + 6, swatches.count)]))
            row.orientation = .horizontal
            row.spacing = 6
            sidebarStack.addArrangedSubview(row)
        }

        func slider(
            _ label: String, value: Double, min: Double, max: Double, action: Selector
        ) {
            sidebarStack.addArrangedSubview(eyebrow(label))
            let control = NSSlider(value: value, minValue: min, maxValue: max,
                                   target: self, action: action)
            control.controlSize = .small
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 162).isActive = true
            sidebarStack.addArrangedSubview(control)
        }
        slider("PADDING", value: backgroundStyle.padding, min: 16, max: 140,
               action: #selector(backgroundPaddingChanged(_:)))
        slider("CORNERS", value: backgroundStyle.cornerRadius, min: 0, max: 28,
               action: #selector(backgroundRadiusChanged(_:)))

        let shadow = NSButton(
            checkboxWithTitle: "Shadow", target: self,
            action: #selector(backgroundShadowChanged(_:)))
        shadow.controlSize = .small
        shadow.state = backgroundStyle.shadow ? .on : .off
        sidebarStack.addArrangedSubview(shadow)
        sidebarStack.setCustomSpacing(14, after: sidebarStack.arrangedSubviews[
            sidebarStack.arrangedSubviews.count - 2])
    }

    // MARK: Options bar contents

    private func rebuildOptionsBar() {
        // Rebuilding while the colour panel drives the well would orphan the
        // panel's target mid-drag — leave the bar alone until it closes.
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible { return }
        for view in optionsStack.arrangedSubviews {
            view.removeFromSuperview()
        }
        defer {
            // No options for this tool → the bar cedes its strip to the canvas.
            optionsBarHeight.constant = optionsStack.arrangedSubviews.isEmpty ? 0 : 34
        }
        if canvas.cropActive {
            let aspect = NSSegmentedControl(
                labels: Self.cropAspects.map(\.label),
                trackingMode: .selectOne, target: self, action: #selector(cropAspectChanged(_:)))
            aspect.controlSize = .small
            aspect.selectedSegment = Self.cropAspects.firstIndex {
                $0.ratio == canvas.cropAspect
            } ?? 0
            let apply = NSButton(title: "Apply", target: self, action: #selector(applyCropTapped))
            apply.keyEquivalent = "\r"
            apply.controlSize = .small
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCropTapped))
            cancel.controlSize = .small
            optionsStack.addArrangedSubview(aspect)
            optionsStack.addArrangedSubview(apply)
            optionsStack.addArrangedSubview(cancel)
            return
        }

        // The lift tool has no styling — the bar coaches the gesture instead.
        if canvas.tool == .lift, canvas.selectedAnnotation == nil {
            let hint = NSTextField(labelWithString: "Click a subject to lift it out")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            optionsStack.addArrangedSubview(hint)
            return
        }

        // Options follow the selection when there is one, else the armed tool.
        let kind = canvas.selectedAnnotation?.kind ?? impliedKind(for: canvas.tool)

        // Image objects (lifted subjects, dropped-in images) get object
        // actions, not styling.
        if kind == .image, let a = canvas.selectedAnnotation, a.kind == .image {
            buildImageObjectOptions(for: a)
            return
        }
        var showColour = false
        var showStroke = false
        var showTextSize = false
        var showTextStyle = false
        var showRedact = false
        var showArrowStyle = false
        switch kind {
        case .some(.highlighter), .some(.counter):
            showColour = true
        case .some(.text):
            (showColour, showTextSize, showTextStyle) = (true, true, true)
        case .some(.redact):
            showRedact = true
        case .some(.spotlight):
            break   // a spotlight has no styling — the veil is fixed
        case .some(.arrow):
            (showColour, showStroke, showArrowStyle) = (true, true, true)
        case .some(.image), .some(.sticker), .none:
            break   // nothing selected, or an object with no styling options
        case .some:
            (showColour, showStroke) = (true, true)
        }

        let activeColour = canvas.selectedAnnotation?.colour ?? canvas.currentColour
        if showColour {
            for (i, entry) in Self.palette.enumerated() {
                optionsStack.addArrangedSubview(
                    swatch(entry.colour, name: entry.name, tag: i, selected: entry.colour == activeColour))
            }
            // Any-colour well after the presets: the classic rainbow circle,
            // opening the shared colour panel (eyedropper included).
            optionsStack.addArrangedSubview(rainbowWell())
        }
        if showStroke {
            let control = NSSegmentedControl(
                labels: Self.strokeWidths.map { "\(Int($0))" },
                trackingMode: .selectOne, target: self, action: #selector(strokeChanged(_:)))
            control.controlSize = .small
            let active = canvas.selectedAnnotation?.lineWidth ?? canvas.currentLineWidth
            control.selectedSegment = Self.strokeWidths.firstIndex(of: active) ?? 1
            optionsStack.addArrangedSubview(control)
        }
        if showTextSize {
            let control = NSSegmentedControl(
                labels: Self.textSizes.map(\.label),
                trackingMode: .selectOne, target: self, action: #selector(textSizeChanged(_:)))
            control.controlSize = .small
            let active = canvas.selectedAnnotation?.textSize ?? canvas.currentTextSize
            control.selectedSegment = Self.textSizes.firstIndex { $0.size == active } ?? 1
            optionsStack.addArrangedSubview(control)
        }
        if showTextStyle {
            let popup = NSPopUpButton()
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 11)
            for style in AnnotatorTextStyle.allCases {
                popup.addItem(withTitle: style.label)
            }
            let active = canvas.selectedAnnotation?.textStyle ?? canvas.currentTextStyle
            popup.selectItem(at: active.rawValue)
            popup.target = self
            popup.action = #selector(textStyleChanged(_:))
            optionsStack.addArrangedSubview(popup)
        }
        if showArrowStyle {
            let control = NSSegmentedControl(
                labels: AnnotatorArrowStyle.allCases.map(\.label),
                trackingMode: .selectOne, target: self, action: #selector(arrowStyleChanged(_:)))
            control.controlSize = .small
            let active = canvas.selectedAnnotation?.arrowStyle ?? canvas.currentArrowStyle
            control.selectedSegment = active.rawValue
            optionsStack.addArrangedSubview(control)
        }
        if showRedact {
            let control = NSSegmentedControl(
                labels: ["Pixelate", "Blur", "Secure", "Black"],
                trackingMode: .selectOne, target: self, action: #selector(redactStyleChanged(_:)))
            control.controlSize = .small
            let active = canvas.selectedAnnotation?.redactStyle ?? canvas.currentRedactStyle
            control.selectedSegment = active.rawValue
            optionsStack.addArrangedSubview(control)
        }
    }

    /// Feather (lifted subjects only), Copy, Detach and a drag-out chip.
    private func buildImageObjectOptions(for a: AnnotatorAnnotation) {
        if let feather = canvas.liftFeather(for: a.id) {
            let label = NSTextField(labelWithString: "Feather")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let slider = NSSlider(
                value: Double(feather), minValue: 0, maxValue: 12,
                target: self, action: #selector(liftFeatherChanged(_:)))
            slider.controlSize = .small
            slider.toolTip = "Soften the cut-out edge"
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
            optionsStack.addArrangedSubview(label)
            optionsStack.addArrangedSubview(slider)
        }
        func action(_ title: String, _ selector: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: selector)
            button.controlSize = .small
            button.bezelStyle = .accessoryBarAction
            button.font = .systemFont(ofSize: 11)
            return button
        }
        optionsStack.addArrangedSubview(action("Copy PNG", #selector(copyObjectTapped)))
        optionsStack.addArrangedSubview(action("Detach as Image", #selector(detachObjectTapped)))
        if let ref = a.imageRef {
            optionsStack.addArrangedSubview(
                ObjectDragChip(image: ref.image, scale: canvas.imageScale))
        }
    }

    private func impliedKind(for tool: AnnotatorTool) -> AnnotatorKind? {
        switch tool {
        case .select, .crop, .lift: return nil
        case .arrow: return .arrow
        case .line: return .line
        case .rect: return .rect
        case .filledRect: return .filledRect
        case .ellipse: return .ellipse
        case .draw: return .freehand
        case .highlighter: return .highlighter
        case .text: return .text
        case .counter: return .counter
        case .redact: return .redact
        case .spotlight: return .spotlight
        }
    }

    private func swatch(_ colour: NSColor, name: String, tag: Int, selected: Bool) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.toolTip = name
        button.wantsLayer = true
        button.layer?.backgroundColor = colour.cgColor
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = selected ? 2 : 1
        button.layer?.borderColor = selected
            ? HUDStyle.accent.cgColor
            : NSColor.separatorColor.cgColor
        button.tag = tag
        button.target = self
        button.action = #selector(swatchTapped(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 16).isActive = true
        button.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return button
    }

    // MARK: Actions

    @objc private func toolTapped(_ sender: NSButton) {
        let tool = AnnotatorTool.allCases[sender.tag]
        // Re-clicking the crop tool toggles it off, cancelling the crop.
        if tool == .crop, canvas.tool == .crop {
            canvas.cancelCrop()
            selectTool(.select)
            return
        }
        selectTool(tool)
    }

    @objc private func sendToTapped(_ sender: NSButton) {
        let destinations = SentryRegistry.destinations()
        guard !destinations.isEmpty else {
            Toast.show("No Sentry apps registered yet", symbol: "paperplane")
            return
        }
        let menu = NSMenu()
        for (i, destination) in destinations.enumerated() {
            let entry = NSMenuItem(
                title: destination.name, action: #selector(sendToDestination(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = i
            if let symbol = destination.symbol {
                entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func sendToDestination(_ sender: NSMenuItem) {
        let destinations = SentryRegistry.destinations()
        guard destinations.indices.contains(sender.tag) else { return }
        // Save first so the receiver reads the current edit, not a stale record.
        guard let still = exportStill(),
              let result = OutputRouter.shared.reExport(
                  still, annotationCount: canvas.annotations.count) else { return }
        SentryRegistry.send(recordID: result.recordID, to: destinations[sender.tag])
    }

    @objc private func pinTapped() {
        guard let still = exportStill() else { return }
        PinController.shared.pin(still)
        Toast.show("Pinned", symbol: "pin")
    }

    private func selectTool(_ tool: AnnotatorTool) {
        canvas.tool = tool
        if let colour = toolColours[tool] { canvas.currentColour = colour }
        if let width = toolWidths[tool] { canvas.currentLineWidth = width }
        refreshChrome()
        window.makeFirstResponder(canvas)
    }

    @objc private func swatchTapped(_ sender: NSButton) {
        canvas.applyColour(Self.palette[sender.tag].colour)
        toolColours[canvas.tool] = Self.palette[sender.tag].colour
        refreshChrome()
        // Refocusing the canvas mid-text-edit force-commits the editor the
        // moment a swatch is touched — leave focus with the editor.
        if !canvas.isEditingText {
            window.makeFirstResponder(canvas)
        }
    }

    /// Hue-wheel circle drawn with a conic gradient — the "any colour" affordance.
    private func rainbowWell() -> NSButton {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.toolTip = "Custom colour"
        button.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.type = .conic
        gradient.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = stride(from: 0.0, through: 1.0, by: 1.0 / 6.0).map {
            NSColor(hue: $0, saturation: 0.85, brightness: 1, alpha: 1).cgColor
        }
        gradient.cornerRadius = 10
        gradient.masksToBounds = true
        gradient.borderWidth = 1
        gradient.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        button.layer?.addSublayer(gradient)
        button.target = self
        button.action = #selector(rainbowWellTapped)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    @objc private func rainbowWellTapped() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = canvas.selectedAnnotation?.colour ?? canvas.currentColour
        panel.setTarget(self)
        panel.setAction(#selector(colourPanelChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colourPanelChanged(_ sender: NSColorPanel) {
        canvas.applyColour(sender.color)
        toolColours[canvas.tool] = sender.color
        // No refreshChrome: the guard above skips rebuilds while the panel is
        // up, and rebuilding mid-drag would orphan the panel's target anyway.
    }

    @objc private func strokeChanged(_ sender: NSSegmentedControl) {
        canvas.applyLineWidth(Self.strokeWidths[sender.selectedSegment])
        toolWidths[canvas.tool] = Self.strokeWidths[sender.selectedSegment]
        window.makeFirstResponder(canvas)
    }

    @objc private func undoTapped() {
        windowUndoManager.undo()
        refreshChrome()
    }

    @objc private func redoTapped() {
        windowUndoManager.redo()
        refreshChrome()
    }

    @objc private func textSizeChanged(_ sender: NSSegmentedControl) {
        canvas.applyTextSize(Self.textSizes[sender.selectedSegment].size)
        if !canvas.isEditingText {
            window.makeFirstResponder(canvas)
        }
    }

    @objc private func redactStyleChanged(_ sender: NSSegmentedControl) {
        if let style = AnnotatorRedactStyle(rawValue: sender.selectedSegment) {
            canvas.applyRedactStyle(style)
        }
        window.makeFirstResponder(canvas)
    }

    @objc private func arrowStyleChanged(_ sender: NSSegmentedControl) {
        if let style = AnnotatorArrowStyle(rawValue: sender.selectedSegment) {
            canvas.applyArrowStyle(style)
        }
        window.makeFirstResponder(canvas)
    }

    @objc private func textStyleChanged(_ sender: NSPopUpButton) {
        if let style = AnnotatorTextStyle(rawValue: sender.indexOfSelectedItem) {
            canvas.applyTextStyle(style)
        }
        if !canvas.isEditingText {
            window.makeFirstResponder(canvas)
        }
    }

    private static let stickerSet = [
        "👍", "👎", "❤️", "🔥", "⭐", "✅", "❌", "⚠️",
        "👀", "🎉", "💡", "❓", "💯", "🚀", "🐛", "🤦",
    ]

    @objc private func stickerTapped(_ sender: NSButton) {
        let menu = NSMenu()
        for emoji in Self.stickerSet {
            let item = NSMenuItem(
                title: emoji, action: #selector(stickerPicked(_:)), keyEquivalent: "")
            item.target = self
            item.attributedTitle = NSAttributedString(
                string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 22)])
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func stickerPicked(_ sender: NSMenuItem) {
        canvas.addSticker(sender.title)
        window.makeFirstResponder(canvas)
    }

    @objc private func adjustTapped() {
        adjustActive.toggle()
        if adjustActive { syncAdjustInspector() }
        inspectorWidth.constant = adjustActive ? 190 : 0
        refreshChrome()
    }

    @objc private func adjustChanged(_ sender: NSSlider) {
        guard let p = AdjustParam(rawValue: sender.tag) else { return }
        var a = canvas.adjustments
        a[p] = CGFloat(sender.doubleValue)
        canvas.setAdjustments(a)
        adjustResets[sender.tag].isEnabled =
            abs(a[p] - CGFloat(p.range.neutral)) >= 0.0001
    }

    @objc private func adjustResetTapped(_ sender: NSButton) {
        guard let p = AdjustParam(rawValue: sender.tag) else { return }
        var a = canvas.adjustments
        a[p] = CGFloat(p.range.neutral)
        canvas.setAdjustments(a)
        syncAdjustInspector()
    }

    @objc private func adjustResetAllTapped() {
        canvas.setAdjustments(ImageAdjustments())
        syncAdjustInspector()
    }

    /// Auto lands as ordinary slider values — the inspector shows exactly
    /// what it decided, every choice stays tweakable, Reset clears it.
    @objc private func autoEnhanceTapped() {
        let auto = ImageAdjustments.auto(for: canvas.baseImage)
        if auto.isIdentity {
            Toast.show("Already looks balanced", symbol: "wand.and.rays")
        }
        canvas.setAdjustments(auto)
        syncAdjustInspector()
        refreshChrome()
        window.makeFirstResponder(canvas)
    }

    @objc private func removeBackgroundTapped() {
        canvas.removeBackground()
        window.makeFirstResponder(canvas)
    }

    @objc private func liftFeatherChanged(_ sender: NSSlider) {
        guard let id = canvas.selectedAnnotation?.id else { return }
        // Preview every tick, commit (one undo entry) on mouse-up.
        let commit = NSApp.currentEvent.map { $0.type == .leftMouseUp } ?? true
        canvas.setLiftFeather(CGFloat(sender.doubleValue), for: id, commit: commit)
    }

    @objc private func copyObjectTapped() {
        guard let a = canvas.selectedAnnotation, let ref = a.imageRef else { return }
        OutputRouter.shared.copyToClipboard(StillCapture(
            image: ref.image, scale: canvas.imageScale, source: source,
            screenRect: nil, hasAlpha: true))
        Toast.show("Copied", symbol: "doc.on.clipboard")
    }

    /// The splice flow: a lifted subject becomes its own editable capture.
    @objc private func detachObjectTapped() {
        guard let a = canvas.selectedAnnotation, let ref = a.imageRef else { return }
        AnnotatorController.shared.open(StillCapture(
            image: ref.image, scale: canvas.imageScale, source: source,
            screenRect: nil, hasAlpha: true))
    }

    @objc private func backgroundTapped() {
        backgroundBarActive.toggle()
        if backgroundBarActive {
            if !backgroundStyle.isVisible {
                backgroundStyle.fill = .gradient(0)
            }
            rebuildBackgroundSidebar()
        }
        sidebarWidth.constant = backgroundBarActive ? 190 : 0
        refreshChrome()
    }

    @objc private func backgroundFillTapped(_ sender: NSButton) {
        switch sender.tag {
        case 0:
            backgroundStyle.fill = .none
        case 1..<100:
            backgroundStyle.fill = .solid(
                AnnotatorBackgroundStyle.solidPresets[sender.tag - 1].colour)
        default:
            backgroundStyle.fill = .gradient(sender.tag - 100)
        }
    }

    @objc private func backgroundPaddingChanged(_ sender: NSSlider) {
        backgroundStyle.padding = CGFloat(sender.doubleValue)
    }

    @objc private func backgroundRadiusChanged(_ sender: NSSlider) {
        backgroundStyle.cornerRadius = CGFloat(sender.doubleValue)
    }

    @objc private func backgroundShadowChanged(_ sender: NSButton) {
        backgroundStyle.shadow = sender.state == .on
    }

    @objc private func cropAspectChanged(_ sender: NSSegmentedControl) {
        canvas.cropAspect = Self.cropAspects[sender.selectedSegment].ratio
        window.makeFirstResponder(canvas)
    }

    @objc private func applyCropTapped() {
        canvas.commitCrop()
    }

    @objc private func cancelCropTapped() {
        canvas.cancelCrop()
    }

    // MARK: Export

    private func exportStill() -> StillCapture? {
        canvas.commitTextEditingIfAny()
        // Invariant 3: adjustments preview live but bake on export/save.
        canvas.bakeAdjustmentsIfNeeded()
        guard let flattened = canvas.flattened() else {
            Toast.show("Could not flatten image", symbol: "exclamationmark.triangle")
            return nil
        }
        let final = AnnotatorRender.applyBackground(
            backgroundStyle, to: flattened, scale: canvas.imageScale) ?? flattened
        // Real transparency (remove-bg, spilled margins) must survive the
        // format choice downstream — a visible background fill re-opaques it.
        return StillCapture(
            image: final, scale: canvas.imageScale, source: source,
            screenRect: nil, origin: origin, recordID: recordID,
            hasAlpha: !backgroundStyle.isVisible && canvas.hasTransparentContent)
    }

    @objc private func copyTapped() {
        guard let still = exportStill() else { return }
        OutputRouter.shared.copyToClipboard(still)
        Toast.show("Copied", symbol: "doc.on.clipboard")
    }

    @objc private func saveTapped() {
        guard let still = exportStill() else { return }
        guard OutputRouter.shared.reExport(still, annotationCount: canvas.annotations.count) != nil
        else { return }
        // Editable state rides along with the record so the capture can be
        // reopened and re-edited — the baked media alone is a dead end.
        if let recordID {
            let project = AnnotatorProject(
                scale: canvas.imageScale,
                baseImage: canvas.baseImage,
                annotations: canvas.annotations,
                background: backgroundStyle)
            if project.write(in: SentryStore.shared.recordDirectory(for: recordID)) {
                SentryStore.shared.amendManifest(id: recordID) {
                    $0.annotations = SentryManifest.Annotations(
                        count: canvas.annotations.count,
                        project: AnnotatorProject.projectFileName)
                }
            }
        }
        Toast.show("Saved", symbol: "square.and.arrow.down")
    }

    @objc private func saveAsTapped() {
        guard let still = exportStill() else { return }
        ExportSheetController.present(over: window, image: still.image, dpiScale: still.scale)
    }

    // MARK: Key handling

    fileprivate func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        // Intersect with just the four modifiers — caps lock / fn / numeric-pad
        // bits must not defeat the match.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), flags.subtracting([.command, .shift]).isEmpty,
              let ch = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = flags.contains(.shift)

        // While a text editor is up, supply the standard editing equivalents
        // ourselves (no main menu in an accessory app) and swallow nothing else.
        if let tv = window.firstResponder as? NSTextView {
            guard tv.isDescendant(of: canvas) else { return false }
            switch (ch, shift) {
            case ("c", false): tv.copy(nil); return true
            case ("v", false): tv.paste(nil); return true
            case ("x", false): tv.cut(nil); return true
            case ("a", false): tv.selectAll(nil); return true
            case ("z", false): tv.undoManager?.undo(); return true
            case ("z", true): tv.undoManager?.redo(); return true
            default: return false
            }
        }

        switch (ch, shift) {
        case ("c", false):
            copyTapped()
        case ("v", false):
            canvas.pasteFromClipboard()
        case ("s", false):
            saveTapped()
        case ("s", true):
            saveAsTapped()
        case ("w", false):
            window.close()
        case ("z", false):
            windowUndoManager.undo()
        case ("z", true):
            windowUndoManager.redo()
        case ("d", false):
            canvas.duplicateSelected()
        case ("]", false):
            canvas.bringSelectionForward()
        case ("[", false):
            canvas.sendSelectionBackward()
        case ("=", _), ("+", _):
            zoom(by: 1.25)
        case ("-", _):
            zoom(by: 0.8)
        case ("0", false):
            setZoom(1)
        default:
            return false
        }
        return true
    }

    fileprivate func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !(window.firstResponder is NSTextView) else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.isDisjoint(with: [.command, .option, .control]),
              let ch = event.charactersIgnoringModifiers?.lowercased(), ch.count == 1
        else { return false }
        if ch == "b" {
            backgroundTapped()
            return true
        }
        if let tool = AnnotatorTool.allCases.first(where: { $0.key == ch }) {
            selectTool(tool)
            return true
        }
        return false
    }

    // MARK: Zoom

    @objc private func zoomInTapped() { zoom(by: 1.25) }
    @objc private func zoomOutTapped() { zoom(by: 0.8) }
    @objc private func zoomActualTapped() { setZoom(1) }

    @objc private func zoomFitTapped() {
        guard let fit = fitMagnification() else { return }
        setZoom(min(fit, 1))
    }

    /// Absolute magnification that fits the whole document. The clip view's
    /// FRAME is the stable measure — its bounds are already divided by the
    /// current magnification, which made Fit drift at any zoom but 100%.
    private func fitMagnification() -> CGFloat? {
        let doc = backdrop.frame.size
        guard doc.width > 0, doc.height > 0 else { return nil }
        let clip = scrollView.contentView.frame.size
        let insets = scrollView.contentInsets
        return min(
            (clip.width - insets.left - insets.right) / doc.width,
            (clip.height - insets.top - insets.bottom) / doc.height)
    }

    /// Zoom OUT (never in) until the document fits — called when the canvas
    /// grows under the user (image merge, padding, spilled annotations).
    private func zoomOutToFitIfNeeded() {
        guard let fit = fitMagnification(), fit < scrollView.magnification else { return }
        setZoom(min(fit, 1))
    }

    private func zoom(by factor: CGFloat) {
        setZoom(scrollView.magnification * factor)
    }

    private func setZoom(_ magnification: CGFloat) {
        let clamped = min(max(magnification, scrollView.minMagnification), scrollView.maxMagnification)
        let visible = scrollView.contentView.bounds
        scrollView.setMagnification(
            clamped, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        refreshZoomLabel()
    }

    private func refreshZoomLabel() {
        zoomLabel.stringValue = "\(Int((scrollView.magnification * 100).rounded()))%"
    }
}

/// Scroll-view document that lays out top-down like the rest of the editor.
private final class AnnotatorFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Object drag-out

/// Draggable proxy of the selected image object — drag it to Finder/Slack to
/// export the object alone as PNG. Dragging the object on the canvas stays a
/// move; this chip is the unambiguous file-drag affordance.
private final class ObjectDragChip: NSView, NSDraggingSource {
    private let image: CGImage
    private let scale: CGFloat

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        toolTip = "Drag out to save as PNG"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inset = bounds.insetBy(dx: 3, dy: 3)
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let f = min(inset.width / w, inset.height / h)
        ctx.draw(image, in: CGRect(
            x: inset.midX - w * f / 2, y: inset.midY - h * f / 2,
            width: w * f, height: h * f))
    }

    override func mouseDown(with event: NSEvent) {
        guard let png = OutputRouter.encodePNG(image: image, dpiScale: scale) else { return }
        let anchor = QAOPromiseDelegate(
            fileName: OutputRouter.shared.nextFileName(ext: "png"),
            sourceURL: nil, fileData: png)
        let provider = QAOImagePromiseProvider(
            fileType: UTType.png.identifier, delegate: anchor)
        provider.anchorDelegate = anchor
        provider.pngData = png
        let item = NSDraggingItem(pasteboardWriter: provider)
        // Drag image: the object at point size, capped so a big cut-out
        // doesn't shroud the drop target.
        var size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if max(size.width, size.height) > 160 {
            let f = 160 / max(size.width, size.height)
            size = NSSize(width: size.width * f, height: size.height * f)
        }
        item.setDraggingFrame(
            NSRect(origin: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY), size: size),
            contents: NSImage(cgImage: image, size: size))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

// MARK: - Backdrop

/// Live preview of the background style: fills its bounds and casts the
/// shadow behind the canvas subview; the canvas's layer corner radius rounds
/// the image itself. Export mirrors this via AnnotatorRender.applyBackground.
private final class AnnotatorBackdropView: NSView {
    var style = AnnotatorBackgroundStyle() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard style.isVisible, let ctx = NSGraphicsContext.current?.cgContext else { return }
        style.drawFill(in: bounds, ctx: ctx)
        guard style.shadow, let canvas = subviews.first else { return }
        let radius = min(style.cornerRadius, canvas.frame.width / 2, canvas.frame.height / 2)
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: style.padding * 0.12),
            blur: max(18, style.padding * 0.35),
            color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.addPath(CGPath(
            roundedRect: canvas.frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
}
