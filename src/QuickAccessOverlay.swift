import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Floating post-capture cards stacked in the bottom-left corner of the
/// screen the mouse is on. Each card is its own non-activating panel so the
/// frontmost app keeps focus while the user copies, saves, annotates, pins
/// or drags the capture out.
@MainActor
final class QuickAccessOverlay {
    static let shared = QuickAccessOverlay()

    private static let maxCards = 5
    private static let margin: CGFloat = 16
    private static let gap: CGFloat = 8

    /// Newest first — index 0 sits nearest the corner.
    private var cards: [QAOCardPanel] = []
    /// Dismissed cards, newest last — "Restore Last Capture Card" pops these.
    private var recentlyClosed: [DeliveredCapture] = []

    var canRestore: Bool { !recentlyClosed.isEmpty }

    private init() {}

    func restoreLastClosed() {
        guard let item = recentlyClosed.popLast() else { return }
        push(item)
    }

    func push(_ item: DeliveredCapture) {
        switch item.payload {
        case .still(let still):
            addCard(item: item, thumbnail: NSImage(cgImage: still.image, size: still.pointSize), video: nil)
        case .video(let video):
            // deliver() moves the recording into place, so prefer fileURL.
            let url = item.fileURL ?? video.url
            Task { [weak self] in
                let meta = await QAOVideoMeta.load(url: url, isGIF: video.isGIF)
                self?.addCard(item: item, thumbnail: meta.thumbnailImage(), video: meta)
            }
        }
    }

    private func addCard(item: DeliveredCapture, thumbnail: NSImage?, video: QAOVideoMeta?) {
        guard let screen = qaoScreenUnderMouse() else { return }
        while cards.count >= Self.maxCards {
            dismiss(cards[cards.count - 1])
        }
        let panel = QAOCardPanel(item: item, thumbnail: thumbnail, video: video, screen: screen)
        panel.cardView.onDismiss = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.dismiss(panel)
        }
        cards.insert(panel, at: 0)
        layout(entering: panel)
        armAutoClose(panel)
    }

    private func dismiss(_ panel: QAOCardPanel) {
        guard let index = cards.firstIndex(where: { $0 === panel }) else { return }
        recentlyClosed.append(panel.cardView.currentItem)
        if recentlyClosed.count > 5 { recentlyClosed.removeFirst() }
        cards.remove(at: index)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: -16, dy: 0), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        layout(entering: nil)
    }

    /// Cards linger while the pointer is on them — the timer re-arms rather
    /// than yanking a card out from under a hover.
    private func armAutoClose(_ panel: QAOCardPanel) {
        let seconds = Settings.shared.qaoAutoCloseSeconds
        guard seconds > 0 else { return }
        Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, let panel, self.cards.contains(where: { $0 === panel }) else { return }
            if NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
                self.armAutoClose(panel)   // hovered: check again in a while
            } else {
                self.dismiss(panel)
            }
        }
    }

    fileprivate func expand(_ panel: QAOCardPanel) {
        panel.userExpanded = true
        layout(entering: nil)
    }

    /// Stack per screen: newest at the corner, older cards pushed up. Beyond
    /// the newest three, cards collapse to their caption band so a burst of
    /// captures doesn't wall off the screen edge — click one to reopen it.
    private func layout(entering: QAOCardPanel?) {
        var cursors: [CGDirectDisplayID: CGFloat] = [:]
        var targets: [(QAOCardPanel, NSRect)] = []
        let rightCorner = Settings.shared.qaoCorner == "bottomRight"
        for (index, panel) in cards.enumerated() {
            guard let screen = panel.homeScreen else { continue }
            panel.isCollapsed = index >= 3 && !panel.userExpanded
            let visible = screen.visibleFrame
            let y = cursors[screen.displayID] ?? (visible.minY + Self.margin)
            let size = panel.isCollapsed
                ? NSSize(width: panel.fullSize.width, height: QAOCardPanel.collapsedHeight)
                : panel.fullSize
            let x = rightCorner
                ? visible.maxX - Self.margin - size.width
                : visible.minX + Self.margin
            targets.append((panel, NSRect(x: x, y: y, width: size.width, height: size.height)))
            cursors[screen.displayID] = y + size.height + Self.gap
        }
        if let entering, let target = targets.first(where: { $0.0 === entering })?.1 {
            entering.setFrame(target.offsetBy(dx: -24, dy: 0), display: false)
            entering.alphaValue = 0
            entering.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (panel, frame) in targets {
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }
    }
}

@MainActor
private func qaoScreenUnderMouse() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        ?? NSScreen.main
        ?? NSScreen.screens.first
}

private func qaoDurationString(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Video metadata

private struct QAOVideoMeta {
    let firstFrame: CGImage?
    let durationSeconds: Double
    let formatLabel: String

    func thumbnailImage() -> NSImage? {
        guard let firstFrame else { return nil }
        return NSImage(cgImage: firstFrame, size: NSSize(width: firstFrame.width, height: firstFrame.height))
    }

    static func load(url: URL, isGIF: Bool) async -> QAOVideoMeta {
        if isGIF { return gifMeta(url: url) }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)
        let frame = try? await generator.image(at: .zero).image
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        return QAOVideoMeta(
            firstFrame: frame,
            durationSeconds: duration.isFinite ? duration : 0,
            formatLabel: "MP4")
    }

    /// AVFoundation can't read GIFs — ImageIO gives the first frame and the
    /// summed frame delays.
    private static func gifMeta(url: URL) -> QAOVideoMeta {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return QAOVideoMeta(firstFrame: nil, durationSeconds: 0, formatLabel: "GIF")
        }
        let frame = CGImageSourceCreateImageAtIndex(source, 0, nil)
        var total: Double = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { continue }
            let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
            total += unclamped.flatMap { $0 > 0 ? $0 : nil } ?? clamped ?? 0.1
        }
        return QAOVideoMeta(firstFrame: frame, durationSeconds: total, formatLabel: "GIF")
    }
}

// MARK: - Panel

@MainActor
private final class QAOCardPanel: NSPanel {
    /// Caption band + border — what a collapsed card shows.
    static let collapsedHeight: CGFloat = 24

    let cardView: QAOCardView
    let fullSize: NSSize
    /// Collapsed cards clip to their caption; a click re-expands (the window
    /// clips content to its frame, so no view surgery is needed).
    var isCollapsed = false
    var userExpanded = false
    private let homeDisplayID: CGDirectDisplayID

    var homeScreen: NSScreen? {
        NSScreen.screens.first { $0.displayID == homeDisplayID } ?? NSScreen.main ?? NSScreen.screens.first
    }

    init(item: DeliveredCapture, thumbnail: NSImage?, video: QAOVideoMeta?, screen: NSScreen) {
        cardView = QAOCardView(item: item, thumbnail: thumbnail, video: video)
        fullSize = cardView.frame.size
        homeDisplayID = screen.displayID
        super.init(
            contentRect: NSRect(origin: .zero, size: cardView.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = cardView
    }
}

// MARK: - Card view

@MainActor
private final class QAOCardView: NSView, NSDraggingSource {
    var onDismiss: (() -> Void)?
    var currentItem: DeliveredCapture { item }

    private var item: DeliveredCapture
    private let thumbnail: NSImage?
    private let isStill: Bool
    /// MP4 recordings with a backing record open in the trim editor.
    private var isEditableVideo: Bool {
        guard case .video(let video) = item.payload else { return false }
        return !video.isGIF && item.recordID != nil
    }
    private var displayImage: NSImage?

    private let scrim = QAOScrimView()
    private var saveButton: QAOIconButton?
    private let captionName = NSTextField(labelWithString: "")
    private let captionMeta = NSTextField(labelWithString: "")
    private var videoMetaText: String?
    private static let captionHeight: CGFloat = 22
    private var mouseDownEvent: NSEvent?
    private var didDrag = false
    /// Drag payload, encoded off-main right after the card appears — a
    /// synchronous full-resolution PNG encode inside mouseDragged freezes the
    /// app for seconds on large captures.
    private var cachedPNG: Data?

    init(item: DeliveredCapture, thumbnail: NSImage?, video: QAOVideoMeta?) {
        self.item = item
        self.thumbnail = thumbnail
        if case .still = item.payload { isStill = true } else { isStill = false }

        let width: CGFloat = 240
        var height: CGFloat = 135
        if let thumbnail, thumbnail.size.width > 0 {
            height = width * thumbnail.size.height / thumbnail.size.width
        }
        height = min(max(height, 70), 170)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height + Self.captionHeight))
        build(video: video)

        if case .still(let still) = item.payload {
            let downscale = Settings.shared.downscaleRetina
            Task.detached(priority: .utility) { [weak self] in
                let data = OutputRouter.encodePNG(
                    image: still.image, dpiScale: still.scale, downscaleTo1x: downscale)
                guard let data else { return }
                await MainActor.run { [weak self] in
                    self?.cachedPNG = data
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func build(video: QAOVideoMeta?) {
        let effect = QAOCardBackgroundView(frame: bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = HUDStyle.cornerRadius
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = HUDStyle.borderColour.cgColor
        addSubview(effect)

        // Thumbnail sits above the caption band (unflipped view: y up).
        let thumbArea = NSRect(
            x: 0, y: Self.captionHeight,
            width: bounds.width, height: bounds.height - Self.captionHeight)
        let imageView = QAOStaticImageView(frame: thumbArea)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        if let thumbnail {
            imageView.image = thumbnail
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            imageView.image = NSImage(systemSymbolName: "film", accessibilityDescription: "Recording")?
                .withSymbolConfiguration(config)
            imageView.contentTintColor = .tertiaryLabelColor
        }
        displayImage = imageView.image
        effect.addSubview(imageView)

        if let video {
            var meta: [String] = []
            if video.durationSeconds > 0 { meta.append(qaoDurationString(video.durationSeconds)) }
            meta.append(video.formatLabel)
            videoMetaText = meta.joined(separator: " · ")
        }
        buildCaption(in: effect)

        scrim.frame = thumbArea
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        scrim.alphaValue = 0
        effect.addSubview(scrim)

        var buttons: [QAOIconButton] = [
            QAOIconButton(symbol: "doc.on.doc", tooltip: "Copy", target: self, action: #selector(copyAction)),
        ]
        let save = QAOIconButton(
            symbol: item.fileURL == nil ? "arrow.down.circle" : "magnifyingglass",
            tooltip: item.fileURL == nil ? "Save" : "Reveal in Finder",
            target: self, action: #selector(saveOrRevealAction))
        saveButton = save
        buttons.append(save)
        if isStill {
            buttons.append(QAOIconButton(
                symbol: "pencil.tip", tooltip: "Annotate", target: self, action: #selector(annotateAction)))
            buttons.append(QAOIconButton(
                symbol: "pin", tooltip: "Pin", target: self, action: #selector(pinAction)))
        }
        if isEditableVideo {
            buttons.append(QAOIconButton(
                symbol: "scissors", tooltip: "Edit", target: self, action: #selector(editVideoAction)))
        }
        let side: CGFloat = 28
        let gap: CGFloat = 10
        let total = CGFloat(buttons.count) * side + CGFloat(buttons.count - 1) * gap
        var x = (bounds.width - total) / 2
        for button in buttons {
            button.frame = NSRect(
                x: x, y: (scrim.bounds.height - side) / 2, width: side, height: side)
            button.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            scrim.addSubview(button)
            x += side + gap
        }

        let close = QAOIconButton(
            symbol: "xmark", tooltip: "Close", target: self, action: #selector(closeAction),
            size: 20, symbolSize: 10, cornerRadius: 10)
        close.frame = NSRect(
            x: scrim.bounds.width - 26, y: scrim.bounds.height - 26, width: 20, height: 20)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        scrim.addSubview(close)
    }

    /// Bottom band: filename (or save state) left, dimensions/duration right —
    /// what this card is, without hovering.
    private func buildCaption(in effect: NSView) {
        let band = QAOCaptionBand(frame: NSRect(
            x: 0, y: 0, width: bounds.width, height: Self.captionHeight))
        band.autoresizingMask = [.width, .maxYMargin]

        captionName.font = .systemFont(ofSize: 10, weight: .medium)
        captionName.textColor = NSColor.white.withAlphaComponent(0.85)
        captionName.lineBreakMode = .byTruncatingMiddle
        captionMeta.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        captionMeta.textColor = NSColor.white.withAlphaComponent(0.55)
        captionMeta.alignment = .right
        for label in [captionName, captionMeta] {
            label.translatesAutoresizingMaskIntoConstraints = false
            band.addSubview(label)
        }
        captionMeta.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            captionName.leadingAnchor.constraint(equalTo: band.leadingAnchor, constant: 8),
            captionName.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            captionMeta.leadingAnchor.constraint(
                greaterThanOrEqualTo: captionName.trailingAnchor, constant: 6),
            captionMeta.trailingAnchor.constraint(equalTo: band.trailingAnchor, constant: -8),
            captionMeta.centerYAnchor.constraint(equalTo: band.centerYAnchor),
        ])
        // Inside the blur view so the card's rounded-corner mask clips it.
        effect.addSubview(band)
        refreshCaption()
    }

    private func refreshCaption() {
        captionName.stringValue = item.fileURL?.lastPathComponent ?? "Not saved yet"
        switch item.payload {
        case .still(let still):
            captionMeta.stringValue = "\(still.image.width)×\(still.image.height)"
        case .video:
            captionMeta.stringValue = videoMetaText ?? ""
        }
    }

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
            scrim.animator().alphaValue = hovering ? 1 : 0
        }
    }

    // MARK: Click + drag-out

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !didDrag else { return }
        let start = down.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        didDrag = true
        beginDragOut(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, !didDrag else { return }
        if let panel = window as? QAOCardPanel, panel.isCollapsed {
            QuickAccessOverlay.shared.expand(panel)
            return
        }
        switch item.payload {
        case .still(let still):
            OutputRouter.shared.openAnnotator(still)
            onDismiss?()
        case .video:
            if isEditableVideo, let recordID = item.recordID {
                VideoEditorController.shared.open(recordID: recordID)
            } else if let url = item.fileURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func beginDragOut(with event: NSEvent) {
        let provider: QAOImagePromiseProvider
        switch item.payload {
        case .still(let still):
            let format = Settings.shared.imageFormat
            let type = (format == .png ? UTType.png : UTType.jpeg).identifier
            let name = item.fileURL?.lastPathComponent
                ?? OutputRouter.shared.nextFileName(ext: format.fileExtension)
            // The promise is fulfilled on a background queue where OutputRouter
            // (@MainActor) can't be used, so data must exist up front. Prefer
            // the background-encoded cache; encode synchronously only when the
            // drag can't proceed without it (no file on disk yet), and skip
            // the raw-PNG extra on big images if the cache isn't ready — the
            // file promise still covers Finder/Slack/browsers.
            let fileData: Data?
            if item.fileURL != nil {
                fileData = nil
            } else if format == .png, let cachedPNG {
                fileData = cachedPNG
            } else {
                fileData = OutputRouter.shared.encode(still, format: format)
            }
            let pngData: Data?
            if let cachedPNG {
                pngData = cachedPNG
            } else if format == .png, fileData != nil {
                pngData = fileData
            } else if still.image.width * still.image.height < 8_000_000 {
                pngData = OutputRouter.shared.encode(still, format: .png)
            } else {
                pngData = nil
            }
            let anchor = QAOPromiseDelegate(fileName: name, sourceURL: item.fileURL, fileData: fileData)
            provider = QAOImagePromiseProvider(fileType: type, delegate: anchor)
            provider.anchorDelegate = anchor
            provider.pngData = pngData
        case .video(let video):
            guard let url = item.fileURL else { return }
            let type = (video.isGIF ? UTType.gif : UTType.mpeg4Movie).identifier
            let anchor = QAOPromiseDelegate(fileName: url.lastPathComponent, sourceURL: url, fileData: nil)
            provider = QAOImagePromiseProvider(fileType: type, delegate: anchor)
            provider.anchorDelegate = anchor
        }
        let dragItem = NSDraggingItem(pasteboardWriter: provider)
        dragItem.setDraggingFrame(bounds, contents: displayImage)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDownEvent = nil
        guard operation != [] else { return }
        // Option at drop keeps the card — CleanShot's keep-in-overlay gesture.
        if !NSEvent.modifierFlags.contains(.option) {
            onDismiss?()
        }
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
        add(item.fileURL == nil ? "Save" : "Reveal in Finder", #selector(saveOrRevealAction))
        if isStill {
            add("Annotate", #selector(annotateAction))
            add("Pin", #selector(pinAction))
            add("Copy Text", #selector(copyTextAction))
        }
        if isEditableVideo {
            add("Edit", #selector(editVideoAction))
        }
        if let recordID = item.recordID {
            let destinations = SentryRegistry.destinations()
            if !destinations.isEmpty {
                menu.addItem(.separator())
                let sendItem = NSMenuItem(title: "Send to", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for destination in destinations {
                    let entry = NSMenuItem(
                        title: destination.name, action: #selector(sendToAction(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = SendPayload(recordID: recordID, destination: destination)
                    if let symbol = destination.symbol {
                        entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                    }
                    submenu.addItem(entry)
                }
                sendItem.submenu = submenu
                menu.addItem(sendItem)
            }
        }
        menu.addItem(.separator())
        if item.fileURL != nil {
            add("Move to Bin", #selector(trashAction))
        }
        add("Close", #selector(closeAction))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Actions

    @objc private func copyAction() {
        switch item.payload {
        case .still(let still):
            OutputRouter.shared.copyToClipboard(still, fileURL: item.fileURL)
        case .video:
            guard let url = item.fileURL else { return }
            OutputRouter.shared.copyFileURL(url)
        }
        Toast.show("Copied", symbol: "doc.on.doc")
    }

    @objc private func saveOrRevealAction() {
        if let url = item.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if case .still(let still) = item.payload {
            guard let result = OutputRouter.shared.reExport(still) else { return }
            item.fileURL = result.url
            item.recordID = result.recordID
            saveButton?.setSymbol("magnifyingglass", tooltip: "Reveal in Finder")
            refreshCaption()
            Toast.show("Saved", symbol: "arrow.down.circle")
        }
    }

    @objc private func annotateAction() {
        guard case .still(let still) = item.payload else { return }
        OutputRouter.shared.openAnnotator(still)
        onDismiss?()
    }

    @objc private func pinAction() {
        guard case .still(let still) = item.payload else { return }
        OutputRouter.shared.pin(still)
        onDismiss?()
    }

    @objc private func editVideoAction() {
        guard let recordID = item.recordID else { return }
        VideoEditorController.shared.open(recordID: recordID)
        onDismiss?()
    }

    @objc private func copyTextAction() {
        guard case .still(let still) = item.payload else { return }
        OutputRouter.shared.copyText(from: still)
    }

    @objc private func trashAction() {
        guard let url = item.fileURL else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            OutputRouter.shared.removeRecent(url)
            onDismiss?()
        } catch {
            NSLog("move to bin failed: \(error)")
            Toast.show("Could not move to Bin", symbol: "exclamationmark.triangle")
        }
    }

    @objc private func closeAction() {
        onDismiss?()
    }

    @objc private func sendToAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SendPayload else { return }
        SentryRegistry.send(recordID: payload.recordID, to: payload.destination)
        onDismiss?()
    }
}

/// NSMenuItem.representedObject needs a class.
private final class SendPayload {
    let recordID: String
    let destination: SentryDestination
    init(recordID: String, destination: SentryDestination) {
        self.recordID = recordID
        self.destination = destination
    }
}

// MARK: - Drag-out plumbing

/// NSFilePromiseProvider.delegate is weak, and the card can be dismissed
/// before the receiver pulls the promise — the provider anchors this so the
/// write always completes.
private final class QAOPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let fileName: String
    private let sourceURL: URL?
    private let fileData: Data?
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    init(fileName: String, sourceURL: URL?, fileData: Data?) {
        self.fileName = fileName
        self.sourceURL = sourceURL
        self.fileData = fileData
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            if let sourceURL {
                try FileManager.default.copyItem(at: sourceURL, to: url)
            } else if let fileData {
                try fileData.write(to: url)
            }
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }
}

/// Serves raw PNG alongside the file promise so image-pasteboard consumers
/// (web drop targets, Slack) work without waiting on the promise.
private final class QAOImagePromiseProvider: NSFilePromiseProvider {
    var pngData: Data?
    var anchorDelegate: QAOPromiseDelegate?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if pngData != nil { types.append(.png) }
        return types
    }

    override func writingOptions(
        forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        type == .png ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .png { return pngData }
        return super.pasteboardPropertyList(forType: type)
    }
}

// MARK: - Passive subviews

/// Blur background that never swallows the card's clicks or drags.
private final class QAOCardBackgroundView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Hover scrim: buttons stay clickable, everything else falls through to the
/// card so drag-out works from anywhere. While faded out the buttons must
/// not swallow clicks — alpha alone doesn't stop hit-testing.
private final class QAOScrimView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.5 else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

private final class QAOStaticImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Caption strip along the card's bottom edge; clicks and drags fall through
/// to the card.
private final class QAOCaptionBand: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class QAOIconButton: NSButton {
    init(
        symbol: String, tooltip: String, target: AnyObject, action: Selector,
        size: CGFloat = 28, symbolSize: CGFloat = 14, cornerRadius: CGFloat = 6
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        imagePosition = .imageOnly
        setSymbol(symbol, tooltip: tooltip, symbolSize: symbolSize)
        contentTintColor = .white
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setSymbol(_ symbol: String, tooltip: String, symbolSize: CGFloat = 14) {
        let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        toolTip = tooltip
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}
