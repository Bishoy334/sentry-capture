import AppKit

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
        if let id = still.recordID,
           SentryStore.shared.loadManifest(for: id)?.annotations?.project != nil,
           let project = AnnotatorProject.load(from: SentryStore.shared.recordDirectory(for: id)) {
            editorStill = StillCapture(
                image: project.baseImage, scale: project.scale, source: still.source,
                screenRect: nil, origin: still.origin, recordID: id)
            restored = project.annotations
        }
        let editor = AnnotatorWindowController(still: editorStill, restoredAnnotations: restored)
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
    private let dimensionsLabel = NSTextField(labelWithString: "")
    private let backdrop = AnnotatorBackdropView()
    private var backgroundButton: NSButton?
    private var backgroundBarActive = false
    private var backgroundStyle = AnnotatorBackgroundStyle() {
        didSet {
            layoutBackdrop()
            refreshChrome()
        }
    }

    /// Toolbar layout: capture-level, shapes, emphasis, ink, then select.
    /// nil entries render as group separators.
    private static let toolbarGroups: [[AnnotatorTool]] = [
        [.crop],
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

    init(still: StillCapture, restoredAnnotations: [AnnotatorAnnotation] = []) {
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
        window.contentView = buildContent()

        canvas.onStateChange = { [weak self] in self?.refreshChrome() }
        canvas.onImageChanged = { [weak self] in
            self?.refreshImageMeta()
            self?.layoutBackdrop()
        }

        sizeWindowToImage()
        refreshImageMeta()
        refreshChrome()
    }

    func show() {
        AppActivation.acquire()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        AppActivation.release()
        onClose?()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        windowUndoManager
    }

    // MARK: Layout

    private func buildContent() -> NSView {
        let content = NSView()

        let toolbar = buildToolbar()
        let optionsBar = buildOptionsBar()
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

        for v in [toolbar, optionsBar, scrollView, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            optionsBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            optionsBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            optionsBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            optionsBar.heightAnchor.constraint(equalToConstant: 34),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
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
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
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

        // Background mode is chrome-level, not a canvas tool — its button
        // lives beside crop but toggles the options bar instead of the tool.
        let background = toolbarIconButton(
            symbol: "photo.on.rectangle", tooltip: "Background (B)",
            action: #selector(backgroundTapped))
        stack.insertArrangedSubview(background, at: 1)
        backgroundButton = background

        // Primary actions live top-right: send, pin, copy, save.
        let send = toolbarIconButton(
            symbol: "paperplane", tooltip: "Send to Sentry app",
            action: #selector(sendToTapped(_:)))
        let pin = toolbarIconButton(
            symbol: "pin", tooltip: "Pin to Screen", action: #selector(pinTapped))
        let copy = toolbarIconButton(
            symbol: "doc.on.doc", tooltip: "Copy (⌘C)", action: #selector(copyTapped))
        let save = toolbarIconButton(
            symbol: "square.and.arrow.down", tooltip: "Save (⌘S)", action: #selector(saveTapped))
        save.contentTintColor = .controlAccentColor
        let actions = NSStackView(views: [send, pin, copy, save])
        actions.orientation = .horizontal
        actions.spacing = 2
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
        NSLayoutConstraint.activate([
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

        let saveAs = NSButton(title: "Save As…", target: self, action: #selector(saveAsTapped))
        saveAs.controlSize = .small
        saveAs.bezelStyle = .accessoryBarAction

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [dimensionsLabel, spacer, saveAs])
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
        var size = NSSize(width: pt.width + 2, height: pt.height + 44 + 34 + 30 + 2)
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
            button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : nil
            button.contentTintColor = selected ? .white : .secondaryLabelColor
        }
        if let backgroundButton {
            let active = backgroundBarActive || backgroundStyle.isVisible
            backgroundButton.layer?.backgroundColor =
                backgroundBarActive ? NSColor.controlAccentColor.cgColor : nil
            backgroundButton.contentTintColor = backgroundBarActive
                ? .white
                : (active ? .controlAccentColor : .secondaryLabelColor)
        }
        rebuildOptionsBar()
    }

    private func layoutBackdrop() {
        let pt = canvas.pointSize
        let pad = backgroundStyle.isVisible ? backgroundStyle.padding : 0
        backdrop.style = backgroundStyle
        backdrop.setFrameSize(NSSize(width: pt.width + pad * 2, height: pt.height + pad * 2))
        canvas.setFrameOrigin(NSPoint(x: pad, y: pad))
        canvas.setFrameSize(pt)
        // The preview rounds the live image the same way the export will.
        canvas.layer?.cornerRadius = backgroundStyle.isVisible ? backgroundStyle.cornerRadius : 0
        canvas.layer?.masksToBounds = backgroundStyle.isVisible
        backdrop.needsDisplay = true
    }

    private func rebuildBackgroundBar() {
        func fillSwatch(_ tag: Int, tooltip: String) -> NSButton {
            let button = NSButton()
            button.title = ""
            button.isBordered = false
            button.setButtonType(.momentaryChange)
            button.toolTip = tooltip
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor.separatorColor.cgColor
            button.tag = tag
            button.target = self
            button.action = #selector(backgroundFillTapped(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 16).isActive = true
            button.heightAnchor.constraint(equalToConstant: 16).isActive = true
            return button
        }

        // Tags: 0 none, 1... solids, 100... gradients.
        let none = fillSwatch(0, tooltip: "No background")
        none.image = NSImage(
            systemSymbolName: "slash.circle", accessibilityDescription: "No background")
        none.contentTintColor = .secondaryLabelColor
        optionsStack.addArrangedSubview(none)
        for (i, preset) in AnnotatorBackgroundStyle.solidPresets.enumerated() {
            let swatch = fillSwatch(1 + i, tooltip: preset.name)
            swatch.layer?.backgroundColor = preset.colour.cgColor
            optionsStack.addArrangedSubview(swatch)
        }
        for (i, preset) in AnnotatorBackgroundStyle.gradientPresets.enumerated() {
            let swatch = fillSwatch(100 + i, tooltip: preset.name)
            let gradient = CAGradientLayer()
            gradient.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
            gradient.cornerRadius = 8
            gradient.colors = preset.colours.map(\.cgColor)
            gradient.startPoint = CGPoint(x: 0, y: 1)
            gradient.endPoint = CGPoint(x: 1, y: 0)
            swatch.layer?.addSublayer(gradient)
            optionsStack.addArrangedSubview(swatch)
        }

        let paddingLabel = NSTextField(labelWithString: "Padding")
        paddingLabel.font = .systemFont(ofSize: 11)
        paddingLabel.textColor = .secondaryLabelColor
        let padding = NSSlider(
            value: backgroundStyle.padding, minValue: 16, maxValue: 140,
            target: self, action: #selector(backgroundPaddingChanged(_:)))
        padding.controlSize = .small
        padding.translatesAutoresizingMaskIntoConstraints = false
        padding.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let radiusLabel = NSTextField(labelWithString: "Corners")
        radiusLabel.font = .systemFont(ofSize: 11)
        radiusLabel.textColor = .secondaryLabelColor
        let radius = NSSlider(
            value: backgroundStyle.cornerRadius, minValue: 0, maxValue: 28,
            target: self, action: #selector(backgroundRadiusChanged(_:)))
        radius.controlSize = .small
        radius.translatesAutoresizingMaskIntoConstraints = false
        radius.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let shadow = NSButton(
            checkboxWithTitle: "Shadow", target: self,
            action: #selector(backgroundShadowChanged(_:)))
        shadow.controlSize = .small
        shadow.state = backgroundStyle.shadow ? .on : .off

        for view in [paddingLabel, padding, radiusLabel, radius, shadow] {
            optionsStack.addArrangedSubview(view)
        }
    }

    // MARK: Options bar contents

    private func rebuildOptionsBar() {
        for view in optionsStack.arrangedSubviews {
            view.removeFromSuperview()
        }
        if backgroundBarActive, !canvas.cropActive {
            rebuildBackgroundBar()
            return
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

        // Options follow the selection when there is one, else the armed tool.
        let kind = canvas.selectedAnnotation?.kind ?? impliedKind(for: canvas.tool)
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
        case .some, .none:
            (showColour, showStroke) = (true, true)
        }

        let activeColour = canvas.selectedAnnotation?.colour ?? canvas.currentColour
        if showColour {
            for (i, entry) in Self.palette.enumerated() {
                optionsStack.addArrangedSubview(
                    swatch(entry.colour, name: entry.name, tag: i, selected: entry.colour == activeColour))
            }
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

    private func impliedKind(for tool: AnnotatorTool) -> AnnotatorKind? {
        switch tool {
        case .select, .crop: return nil
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
            ? NSColor.controlAccentColor.cgColor
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
        selectTool(AnnotatorTool.allCases[sender.tag])
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
        window.makeFirstResponder(canvas)
    }

    @objc private func swatchTapped(_ sender: NSButton) {
        canvas.applyColour(Self.palette[sender.tag].colour)
        refreshChrome()
        // Refocusing the canvas mid-text-edit force-commits the editor the
        // moment a swatch is touched — leave focus with the editor.
        if !canvas.isEditingText {
            window.makeFirstResponder(canvas)
        }
    }

    @objc private func strokeChanged(_ sender: NSSegmentedControl) {
        canvas.applyLineWidth(Self.strokeWidths[sender.selectedSegment])
        window.makeFirstResponder(canvas)
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

    @objc private func backgroundTapped() {
        backgroundBarActive.toggle()
        if backgroundBarActive, !backgroundStyle.isVisible {
            backgroundStyle.fill = .gradient(0)
        }
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
        guard let flattened = canvas.flattened() else {
            Toast.show("Could not flatten image", symbol: "exclamationmark.triangle")
            return nil
        }
        let final = AnnotatorRender.applyBackground(
            backgroundStyle, to: flattened, scale: canvas.imageScale) ?? flattened
        return StillCapture(
            image: final, scale: canvas.imageScale, source: source,
            screenRect: nil, origin: origin, recordID: recordID)
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
                annotations: canvas.annotations)
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
        OutputRouter.shared.saveAs(still, over: window)
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

    private func zoom(by factor: CGFloat) {
        setZoom(scrollView.magnification * factor)
    }

    private func setZoom(_ magnification: CGFloat) {
        let clamped = min(max(magnification, scrollView.minMagnification), scrollView.maxMagnification)
        let visible = scrollView.contentView.bounds
        scrollView.setMagnification(
            clamped, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
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
