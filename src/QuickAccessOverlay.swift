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
    /// Chevron toggle: slide the whole stack off-screen and back.
    private var stackHidden = false
    private var chevron: QAOChevronPanel?

    var canRestore: Bool { !recentlyClosed.isEmpty }

    private init() {
        // Displays come and go (monitor sleep/unplug). homeScreen already
        // falls back to the main screen while a card's display is missing —
        // this re-lays-out so cards actually move there and move back when
        // the display returns, instead of stranding at stale coordinates.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let overlay = QuickAccessOverlay.shared
                guard !overlay.cards.isEmpty, !overlay.stackHidden else { return }
                overlay.layout(entering: nil)
            }
        }
    }

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
        // A fresh capture always reveals the stack — that's what it's for.
        if stackHidden { setStackHidden(false) }
        layout(entering: panel)
        armAutoClose(panel)
    }

    fileprivate func setStackHidden(_ hidden: Bool) {
        guard stackHidden != hidden else { return }
        stackHidden = hidden
        chevron?.setCollapsed(hidden, count: cards.count)
        if hidden {
            for panel in cards {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().alphaValue = 0
                    panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -36), display: true)
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        if self.stackHidden { panel.orderOut(nil) }
                    }
                })
            }
        } else {
            for panel in cards { panel.orderFrontRegardless() }
            layout(entering: nil)   // slides frames back and fades alpha in
        }
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
            // The chevron pill owns the corner itself; cards stack above it.
            let y = cursors[screen.displayID]
                ?? (visible.minY + Self.margin + QAOChevronPanel.height + Self.gap)
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
        updateChevron()
    }

    private func updateChevron() {
        guard let screen = cards.first?.homeScreen else {
            chevron?.orderOut(nil)
            chevron = nil
            stackHidden = false
            return
        }
        if chevron == nil {
            chevron = QAOChevronPanel { [weak self] in
                guard let self else { return }
                self.setStackHidden(!self.stackHidden)
            }
        }
        let visible = screen.visibleFrame
        // Centre the pill under the card column so it reads as the stack's base.
        let cardWidth = cards.first?.fullSize.width ?? 220
        let inset = max(0, (cardWidth - QAOChevronPanel.width) / 2)
        let x = Settings.shared.qaoCorner == "bottomRight"
            ? visible.maxX - Self.margin - cardWidth + inset
            : visible.minX + Self.margin + inset
        chevron?.setFrameOrigin(NSPoint(x: x, y: visible.minY + Self.margin))
        chevron?.setCollapsed(stackHidden, count: cards.count)
        chevron?.orderFrontRegardless()
    }
}

// MARK: - Corner control strip

/// Compact pill under the stack. More than a hide/show chevron: it opens
/// the capture library and starts a new capture, so the corner works
/// without a trip to the menu-bar icon.
@MainActor
private final class QAOChevronPanel: NSPanel {
    static let width: CGFloat = 124
    static let height: CGFloat = 28

    private let onToggle: () -> Void
    private let toggleButton = NSButton()

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let card = HUDStyle.card()
        card.layer?.cornerRadius = Self.height / 2
        // Behind-window blur alone goes wallpaper-coloured; a dark wash keeps
        // the pill reading as chrome, matching the all-in-one strip.
        let wash = NSView()
        wash.wantsLayer = true
        wash.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        wash.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(wash)

        toggleButton.isBordered = false
        toggleButton.setButtonType(.momentaryChange)
        toggleButton.contentTintColor = .white
        toggleButton.target = self
        toggleButton.action = #selector(tapped)

        let library = QAOIconButton(
            symbol: "square.grid.2x2", tooltip: "Open capture library",
            target: self, action: #selector(libraryTapped), size: 24, symbolSize: 12)
        let capture = QAOIconButton(
            symbol: "viewfinder", tooltip: "New capture",
            target: self, action: #selector(captureTapped), size: 24, symbolSize: 12)

        for view in [toggleButton, library, capture] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            wash.topAnchor.constraint(equalTo: card.topAnchor),
            wash.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            toggleButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            toggleButton.widthAnchor.constraint(equalToConstant: 44),
            toggleButton.topAnchor.constraint(equalTo: card.topAnchor),
            toggleButton.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            capture.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            capture.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            capture.widthAnchor.constraint(equalToConstant: 24),
            capture.heightAnchor.constraint(equalToConstant: 24),
            library.trailingAnchor.constraint(equalTo: capture.leadingAnchor, constant: -6),
            library.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            library.widthAnchor.constraint(equalToConstant: 24),
            library.heightAnchor.constraint(equalToConstant: 24),
        ])
        contentView = card
        setCollapsed(false)
    }

    func setCollapsed(_ collapsed: Bool, count: Int = 0) {
        toggleButton.image = NSImage(
            systemSymbolName: collapsed ? "chevron.up" : "chevron.down",
            accessibilityDescription: collapsed ? "Show captures" : "Hide captures")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        toggleButton.contentTintColor = .white
        // Collapsed, the strip is all that remains — advertise the hidden
        // stack with a count instead of a bare, meaningless chevron.
        if collapsed && count > 0 {
            toggleButton.imagePosition = .imageLeading
            toggleButton.attributedTitle = NSAttributedString(string: " \(count)", attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 11, weight: .bold)])
        } else {
            toggleButton.imagePosition = .imageOnly
            toggleButton.title = ""
        }
        toggleButton.toolTip = collapsed
            ? "Show \(count) capture\(count == 1 ? "" : "s")"
            : "Hide captures"
    }

    @objc private func tapped() {
        onToggle()
    }

    @objc private func libraryTapped() {
        HistoryController.shared.show()
    }

    @objc private func captureTapped() {
        (NSApp.delegate as? AppDelegate)?.dispatch(.captureArea)
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
    var userExpanded = false
    private let homeDisplayID: CGDirectDisplayID

    var homeScreen: NSScreen? {
        NSScreen.screens.first { $0.displayID == homeDisplayID } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Collapsed cards clip to their name band; a click re-expands (the
    /// window clips content to its frame, so no view surgery is needed).
    var isCollapsed = false

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

    /// Borderless panels refuse key status by default — the inline rename
    /// field needs it (and becomesKeyOnlyIfNeeded keeps everything else
    /// click-through as before).
    override var canBecomeKey: Bool { true }
}

// MARK: - Card view

@MainActor
private final class QAOCardView: NSView, NSDraggingSource, NSTextFieldDelegate {
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
    private let captionBand = QAOCaptionBand(frame: .zero)
    private let captionName = QAORenameField(labelWithString: "")
    private var videoMetaText: String?
    /// When the card appeared — drives the "Just now / 2m ago" recency cue
    /// in the tooltip.
    private let createdAt = Date()
    private static let captionHeight: CGFloat = 24
    /// True while a rename holds app activation (released on commit/cancel).
    private var renameActivation = false
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

        let width: CGFloat = 220
        var height: CGFloat = 126
        if let thumbnail, thumbnail.size.width > 0 {
            height = width * thumbnail.size.height / thumbnail.size.width
        }
        // Floor guarantees room for the icon rails — panoramas letterbox on
        // the blur instead of starving the controls.
        height = min(max(height, 118), 165)
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

        // Full-bleed image above a slim name band — metadata rides the
        // tooltip, not the card.
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

        // The scrim dims the image on hover; the action buttons ride it.
        scrim.frame = bounds
        scrim.autoresizingMask = [.width, .height]
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        scrim.alphaValue = 0
        effect.addSubview(scrim)

        // Big readable hover actions: primaries down the left edge,
        // secondaries (pin, more) down the right, close in the corner.
        var left: [QAOIconButton] = [
            QAOIconButton(
                symbol: "doc.on.doc", tooltip: "Copy", target: self,
                action: #selector(copyAction), size: 32, symbolSize: 15),
        ]
        let save = QAOIconButton(
            symbol: item.fileURL == nil ? "arrow.down.circle" : "folder",
            tooltip: item.fileURL == nil ? "Save" : "Reveal in Finder",
            target: self, action: #selector(saveOrRevealAction), size: 32, symbolSize: 15)
        saveButton = save
        left.append(save)
        if isStill {
            left.append(QAOIconButton(
                symbol: "pencil", tooltip: "Annotate", target: self,
                action: #selector(annotateAction), size: 32, symbolSize: 15))
        }
        if isEditableVideo {
            left.append(QAOIconButton(
                symbol: "scissors", tooltip: "Edit", target: self,
                action: #selector(editVideoAction), size: 32, symbolSize: 15))
        }
        var right: [QAOIconButton] = []
        if isStill {
            right.append(QAOIconButton(
                symbol: "pin", tooltip: "Pin", target: self,
                action: #selector(pinAction), size: 32, symbolSize: 15))
        }
        // Every hidden action (OCR, Send to, Convert, Move to Bin) also lives
        // in the right-click menu; this keeps that menu discoverable.
        right.append(QAOIconButton(
            symbol: "ellipsis.circle", tooltip: "More…", target: self,
            action: #selector(moreActions(_:)), size: 32, symbolSize: 15))

        let side: CGFloat = 32
        let gap: CGFloat = 6
        // reservedTop keeps the right column clear of the close button.
        func place(_ column: [QAOIconButton], x: CGFloat, reservedTop: CGFloat, mask: NSView.AutoresizingMask) {
            let total = CGFloat(column.count) * side + CGFloat(column.count - 1) * gap
            var y = Self.captionHeight + (thumbArea.height - reservedTop - total) / 2
            for button in column.reversed() {
                button.frame = NSRect(x: x, y: y, width: side, height: side)
                button.autoresizingMask = mask.union([.minYMargin, .maxYMargin])
                scrim.addSubview(button)
                y += side + gap
            }
        }
        place(left, x: 10, reservedTop: 0, mask: [.maxXMargin])
        place(right, x: bounds.width - 10 - side, reservedTop: 26, mask: [.minXMargin])

        let close = QAOIconButton(
            symbol: "xmark", tooltip: "Close", target: self, action: #selector(closeAction),
            size: 22, symbolSize: 11, cornerRadius: 11)
        close.frame = NSRect(
            x: scrim.bounds.width - 28, y: scrim.bounds.height - 28, width: 22, height: 22)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        scrim.addSubview(close)
    }

    /// Slim bottom band: just the capture's name, editable in place.
    private func buildCaption(in effect: NSView) {
        captionBand.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.captionHeight)
        captionBand.autoresizingMask = [.width, .maxYMargin]
        effect.addSubview(captionBand)

        captionName.isBordered = false
        captionName.drawsBackground = false
        captionName.focusRingType = .none
        captionName.usesSingleLineMode = true
        captionName.delegate = self
        captionName.font = .systemFont(ofSize: 11.5, weight: .medium)
        captionName.textColor = NSColor.white.withAlphaComponent(0.9)
        captionName.lineBreakMode = .byTruncatingMiddle
        // Editing arms only on a deliberate click — an always-editable field
        // steals first responder (and shows a selection) whenever the panel
        // happens to become key.
        captionName.canRename = { [weak self] in
            guard let self, let panel = self.window as? QAOCardPanel else { return false }
            return !panel.isCollapsed && self.item.fileURL != nil
        }
        captionName.onArm = { [weak self] in
            guard let self, !self.renameActivation else { return }
            self.renameActivation = true
            AppActivation.acquire()
        }
        captionName.translatesAutoresizingMaskIntoConstraints = false
        captionBand.addSubview(captionName)
        NSLayoutConstraint.activate([
            captionName.leadingAnchor.constraint(equalTo: captionBand.leadingAnchor, constant: 10),
            captionName.trailingAnchor.constraint(lessThanOrEqualTo: captionBand.trailingAnchor, constant: -10),
            captionName.centerYAnchor.constraint(equalTo: captionBand.centerYAnchor),
        ])
        refreshCaption()
    }

    /// A friendly recency cue — the card stack is newest-at-corner, but nothing
    /// else on the card says so. The full filename lives in the tooltip.
    private func relativeTimeString() -> String {
        let elapsed = Date().timeIntervalSince(createdAt)
        if elapsed < 45 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }

    private func refreshCaption() {
        captionName.isEditable = false
        let stem = item.fileURL?.deletingPathExtension().lastPathComponent
        captionName.stringValue = stem ?? "Not saved"
        // Metadata lives in the tooltip — the card itself stays clean.
        var meta: [String] = []
        switch item.payload {
        case .still(let still):
            meta.append("\(still.image.width)×\(still.image.height)")
            if let url = item.fileURL,
               let bytes = (try? FileManager.default.attributesOfItem(
                   atPath: url.path)[.size]) as? Int, bytes > 0 {
                let size = ByteCountFormatter.string(
                    fromByteCount: Int64(bytes), countStyle: .file)
                meta.append("\(size) \(url.pathExtension.uppercased())")
            }
        case .video:
            if let videoMetaText { meta.append(videoMetaText) }
        }
        meta.append(relativeTimeString())
        let metaLine = meta.joined(separator: " · ")
        captionName.toolTip = stem == nil ? metaLine : "\(metaLine) — click to rename"
        toolTip = metaLine
    }

    // MARK: Inline rename

    func controlTextDidBeginEditing(_ obj: Notification) {
        (captionName.currentEditor() as? NSTextView)?.insertionPointColor = .white
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitRename()
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            refreshCaption()
            window?.makeFirstResponder(nil)
            return true
        }
        // The name field wraps, so Return would insert a newline — commit.
        if selector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    /// Renames the file on disk (and the record's manifest when there is
    /// one), keeping Recents pointed at the new URL.
    private func commitRename() {
        if renameActivation {
            renameActivation = false
            AppActivation.release()
        }
        defer { window?.makeFirstResponder(nil) }
        guard let url = item.fileURL else { refreshCaption(); return }
        let stem = captionName.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
        guard !stem.isEmpty, stem != url.deletingPathExtension().lastPathComponent else {
            refreshCaption()
            return
        }
        let newName = "\(stem).\(url.pathExtension)"
        let newURL: URL?
        if let id = item.recordID {
            newURL = SentryStore.shared.renameMedia(recordID: id, to: newName)
        } else {
            let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
            newURL = (try? FileManager.default.moveItem(at: url, to: dest)) != nil ? dest : nil
        }
        guard let newURL else {
            Toast.show("Could not rename", symbol: "exclamationmark.triangle")
            refreshCaption()
            return
        }
        OutputRouter.shared.replaceRecent(url, with: newURL)
        item = DeliveredCapture(payload: item.payload, fileURL: newURL, recordID: item.recordID)
        refreshCaption()
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
        let collapsed = (window as? QAOCardPanel)?.isCollapsed ?? false
        // Keep the recency tooltip honest on interaction (it doesn't tick);
        // a collapsed sliver advertises click-to-expand instead.
        if collapsed {
            toolTip = "Click to expand"
        } else if hovering {
            refreshCaption()
        }
        captionBand.setHighlighted(hovering && collapsed)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            scrim.animator().alphaValue = (hovering && !collapsed) ? 1 : 0
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
        NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
    }

    /// The full action set, shared by right-click and the "More…" hover button
    /// so both stay in sync.
    private func makeMenu() -> NSMenu {
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
            let convertItem = NSMenuItem(title: "Convert To", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for format in ExportFormat.allCases {
                let entry = NSMenuItem(
                    title: format.label, action: #selector(convertAction(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = format.rawValue
                submenu.addItem(entry)
            }
            convertItem.submenu = submenu
            menu.addItem(convertItem)
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
        return menu
    }

    @objc private func moreActions(_ sender: NSButton) {
        makeMenu().popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height + 4),
            in: sender)
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
        } else if case .still(var still) = item.payload {
            guard let result = OutputRouter.shared.reExport(still) else { return }
            // Rebuild the payload so annotate/copyText/convert/drag key off the
            // saved record instead of the stale nil-id still (which forked a
            // duplicate history entry).
            still.recordID = result.recordID
            item = DeliveredCapture(
                payload: .still(still), fileURL: result.url, recordID: result.recordID)
            saveButton?.setSymbol("folder", tooltip: "Reveal in Finder")
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

    @objc private func convertAction(_ sender: NSMenuItem) {
        guard case .still(let still) = item.payload,
              let raw = sender.representedObject as? String,
              let format = ExportFormat(rawValue: raw) else { return }
        let name = item.fileURL?.deletingPathExtension().lastPathComponent ?? "Capture"
        ImageExporter.convertFlow(
            image: still.image, dpiScale: still.scale, suggestedName: name, to: format)
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
/// write always completes. Internal: the annotator's object drag-out reuses
/// this same plumbing.
final class QAOPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
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
final class QAOImagePromiseProvider: NSFilePromiseProvider {
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

/// Card-name label that turns into an editor only on a deliberate click —
/// never grabs first responder just because its panel became key.
private final class QAORenameField: NSTextField {
    var canRename: () -> Bool = { false }

    /// Labels normally pass clicks through — reclaim them while renaming is
    /// possible (point arrives in superview coordinates).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEditable || canRename(), frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    /// The card panel is non-activating; without this the panel never
    /// becomes key on click and typed text lands in the frontmost app.
    override var needsPanelToBecomeKey: Bool { true }

    /// Runs as editing arms — the card borrows app activation here so the
    /// keyboard reliably routes to the field, and returns it on commit.
    var onArm: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        if !isEditable, canRename() {
            isEditable = true
            onArm()
            // Activation (onArm) brings the app's regular windows forward and
            // one may grab key — re-assert the panel after that settles or
            // typing lands in an open editor window instead of this field.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeKey()
                self.window?.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
            }
            return
        }
        super.mouseDown(with: event)
    }
}

/// Name strip along the card's bottom edge. No hitTest override: the rename
/// field claims its own clicks, everything else bubbles up to the card (so
/// drag-out and click-to-expand still work from the band).
private final class QAOCaptionBand: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Brightens on hover as a click-to-expand cue for collapsed slivers.
    func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on
            ? NSColor.white.withAlphaComponent(0.16).cgColor
            : NSColor.black.withAlphaComponent(0.4).cgColor
    }
}

private final class QAOIconButton: NSButton {
    private static let restBackground = NSColor.white.withAlphaComponent(0.10).cgColor
    private static let hoverBackground = NSColor.white.withAlphaComponent(0.24).cgColor

    init(
        symbol: String, tooltip: String, target: AnyObject, action: Selector,
        size: CGFloat = 28, symbolSize: CGFloat = 14, cornerRadius: CGFloat? = nil
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        imagePosition = .imageOnly
        setSymbol(symbol, tooltip: tooltip, symbolSize: symbolSize)
        contentTintColor = .white
        self.target = target
        self.action = action
        wantsLayer = true
        // A persistent circular container so the glyphs read as tap targets at
        // rest, not watermark decoration; hover just brightens it.
        layer?.cornerRadius = cornerRadius ?? size / 2
        layer?.backgroundColor = Self.restBackground
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
        layer?.backgroundColor = Self.hoverBackground
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = Self.restBackground
    }
}
