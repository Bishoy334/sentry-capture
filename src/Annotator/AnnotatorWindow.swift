import AppKit

// MARK: - Controller (public contract)

@MainActor
final class AnnotatorController {
    static let shared = AnnotatorController()

    private var editors: [AnnotatorWindowController] = []

    private init() {}

    /// One editor window per capture; multiple may be open at once.
    func open(_ still: StillCapture) {
        guard still.image.width > 0, still.image.height > 0 else {
            Toast.show("Nothing to annotate", symbol: "exclamationmark.triangle")
            return
        }
        let editor = AnnotatorWindowController(still: still)
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

    /// Toolbar layout: capture-level, shapes, emphasis, ink, then select.
    /// nil entries render as group separators.
    private static let toolbarGroups: [[AnnotatorTool]] = [
        [.crop],
        [.arrow, .line, .rect, .filledRect, .ellipse],
        [.highlighter, .redact, .counter],
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

    init(still: StillCapture) {
        source = still.source
        origin = still.origin
        recordID = still.recordID
        canvas = AnnotatorCanvas(still: still)
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
        canvas.onImageChanged = { [weak self] in self?.refreshImageMeta() }

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

        scrollView.documentView = canvas
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

        // Primary actions live top-right: pin, copy, save.
        let pin = toolbarIconButton(
            symbol: "pin", tooltip: "Pin to Screen", action: #selector(pinTapped))
        let copy = toolbarIconButton(
            symbol: "doc.on.doc", tooltip: "Copy (⌘C)", action: #selector(copyTapped))
        let save = toolbarIconButton(
            symbol: "square.and.arrow.down", tooltip: "Save (⌘S)", action: #selector(saveTapped))
        save.contentTintColor = .controlAccentColor
        let actions = NSStackView(views: [pin, copy, save])
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
        rebuildOptionsBar()
    }

    // MARK: Options bar contents

    private func rebuildOptionsBar() {
        for view in optionsStack.arrangedSubviews {
            view.removeFromSuperview()
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
        let showColour: Bool
        let showStroke: Bool
        let showTextSize: Bool
        let showRedact: Bool
        switch kind {
        case .some(.highlighter), .some(.counter):
            (showColour, showStroke, showTextSize, showRedact) = (true, false, false, false)
        case .some(.text):
            (showColour, showStroke, showTextSize, showRedact) = (true, false, true, false)
        case .some(.redact):
            (showColour, showStroke, showTextSize, showRedact) = (false, false, false, true)
        case .some:
            (showColour, showStroke, showTextSize, showRedact) = (true, true, false, false)
        case .none:
            (showColour, showStroke, showTextSize, showRedact) = (true, true, false, false)
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
        if showRedact {
            let control = NSSegmentedControl(
                labels: ["Pixelate", "Blur", "Black"],
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
        return StillCapture(
            image: flattened, scale: canvas.imageScale, source: source,
            screenRect: nil, origin: origin, recordID: recordID)
    }

    @objc private func copyTapped() {
        guard let still = exportStill() else { return }
        OutputRouter.shared.copyToClipboard(still)
        Toast.show("Copied", symbol: "doc.on.clipboard")
    }

    @objc private func saveTapped() {
        guard let still = exportStill() else { return }
        if OutputRouter.shared.reExport(still, annotationCount: canvas.annotations.count) != nil {
            Toast.show("Saved", symbol: "square.and.arrow.down")
        }
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
