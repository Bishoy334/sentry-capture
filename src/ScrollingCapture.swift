import Accelerate
import AppKit
import CoreVideo
import ScreenCaptureKit
import Vision

/// Scrolling capture: the user selects a region, scrolls (or lets us scroll),
/// and frames are registered and stitched into one tall image. Vision's
/// stateful translational tracker does the per-frame registration; a vDSP
/// normalised-cross-correlation matcher is the fallback and the sign oracle.
@MainActor
final class ScrollingCaptureController {
    static let shared = ScrollingCaptureController()

    private init() {}

    private var session: ScrollingSession?

    /// AppDelegate gates every other capture flow on this — a second overlay
    /// over a live scrolling session gets stitched into the document.
    var isActive: Bool { session != nil }

    func begin(selection: SelectionController.Selection) {
        guard session == nil else { return }
        // Window picks just borrow the window's frame — the capture itself
        // stays a display-filter rect so scrolled-in content keeps arriving.
        let raw = (selection.window?.frame ?? selection.rect).standardized
        let rect = raw.intersection(selection.display.frame).integral
        guard rect.width >= 50, rect.height >= 50 else {
            Toast.show("Selection too small for scrolling capture", symbol: "rectangle.dashed")
            return
        }
        let session = ScrollingSession(
            rect: rect,
            display: selection.display,
            origin: CaptureOrigin.frontmost(displayID: selection.display.displayID)
        ) { [weak self] in
            self?.session = nil
        }
        self.session = session
        session.start()
    }
}

// MARK: - Session (UI + poll-task lifecycle)

@MainActor
private final class ScrollingSession {
    /// Capture region, global CG top-left points.
    private let rect: CGRect
    private let display: SCDisplay
    private let origin: CaptureOrigin?
    private let onEnd: () -> Void
    private let flags = ScrollingSessionFlags()

    private var borderPanel: NSPanel?
    private var hudPanel: ScrollingHUDPanel?
    private var statusLabel: NSTextField?
    private var pollTask: Task<Void, Never>?
    private var uiTornDown = false
    private var ended = false

    init(rect: CGRect, display: SCDisplay, origin: CaptureOrigin?, onEnd: @escaping () -> Void) {
        self.rect = rect
        self.display = display
        self.origin = origin
        self.onEnd = onEnd
    }

    func start() {
        showBorder()
        showHUD()
        let rect = self.rect
        let display = self.display
        let flags = self.flags
        pollTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await ScrollingSession.run(rect: rect, display: display, flags: flags, session: self)
        }
    }

    // MARK: Border chrome

    private func showBorder() {
        // Grown past the border thickness so the accent ring hugs the outside
        // of the capture rect with 1pt clearance — the filter excludes
        // nothing of ours, so not even an antialiased fringe of accent may
        // sample into the sourceRect.
        let frameCG = rect.insetBy(dx: -3, dy: -3)
        let panel = NSPanel(
            contentRect: Coords.appKitRect(fromCG: frameCG),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = ScrollingBorderView()
        panel.orderFrontRegardless()
        borderPanel = panel
    }

    // MARK: HUD

    private func showHUD() {
        let status = NSTextField(labelWithString: "Scroll the content, then press Done")
        status.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        status.textColor = .labelColor

        let autoSwitch = NSSwitch()
        autoSwitch.controlSize = .small
        autoSwitch.target = self
        autoSwitch.action = #selector(autoScrollToggled(_:))
        let autoLabel = NSTextField(labelWithString: "Auto-scroll")
        autoLabel.font = .systemFont(ofSize: 12)
        autoLabel.textColor = .secondaryLabelColor

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r" // default button — accent fill

        let stack = NSStackView(views: [status, autoSwitch, autoLabel, cancel, done])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 12)
        stack.setCustomSpacing(18, after: status)
        stack.setCustomSpacing(6, after: autoSwitch)
        stack.setCustomSpacing(18, after: autoLabel)
        // The status text only ever gets shorter ("Captured N px"); pinning
        // its width keeps the card from resizing under the pointer.
        status.widthAnchor.constraint(greaterThanOrEqualToConstant: status.fittingSize.width)
            .isActive = true

        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        let size = stack.fittingSize
        let panel = ScrollingHUDPanel(
            contentRect: Coords.appKitRect(fromCG: hudPlacement(size: size)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = card
        panel.onEscape = { [weak self] in self?.cancelTapped() }
        panel.makeKeyAndOrderFront(nil) // key (non-activating) so Esc reaches us

        hudPanel = panel
        statusLabel = status
    }

    /// HUD spot in CG space: below the region, else above, else beside —
    /// never intersecting the capture rect, because the filter would capture
    /// it. Only a display-filling region forces an overlap.
    private func hudPlacement(size: NSSize) -> CGRect {
        let gap: CGFloat = 12
        let margin: CGFloat = 8
        let bounds = display.frame

        func clampedX(_ x: CGFloat) -> CGFloat {
            min(max(x, bounds.minX + margin), bounds.maxX - size.width - margin)
        }
        func clampedY(_ y: CGFloat) -> CGFloat {
            min(max(y, bounds.minY + margin), bounds.maxY - size.height - margin)
        }

        let centredX = clampedX(rect.midX - size.width / 2)
        if rect.maxY + gap + size.height <= bounds.maxY {
            return CGRect(x: centredX, y: rect.maxY + gap, width: size.width, height: size.height)
        }
        if rect.minY - gap - size.height >= bounds.minY {
            return CGRect(
                x: centredX, y: rect.minY - gap - size.height,
                width: size.width, height: size.height)
        }
        if rect.maxX + gap + size.width <= bounds.maxX {
            return CGRect(
                x: rect.maxX + gap, y: clampedY(rect.midY - size.height / 2),
                width: size.width, height: size.height)
        }
        if rect.minX - gap - size.width >= bounds.minX {
            return CGRect(
                x: rect.minX - gap - size.width, y: clampedY(rect.midY - size.height / 2),
                width: size.width, height: size.height)
        }
        return CGRect(
            x: centredX, y: rect.maxY - gap - size.height,
            width: size.width, height: size.height)
    }

    // MARK: Actions

    @objc private func autoScrollToggled(_ sender: NSSwitch) {
        let wantOn = sender.state == .on
        // Synthetic scroll events are Accessibility-gated (separate from the
        // Screen Recording grant).
        if wantOn, !CGPreflightPostEventAccess(), !CGRequestPostEventAccess() {
            sender.state = .off
            flags.autoScroll = false
            Toast.show("Enable Accessibility for auto-scroll", symbol: "hand.raised")
            return
        }
        flags.autoScroll = wantOn
    }

    @objc private func cancelTapped() {
        guard !ended, !flags.finishRequested else { return }
        flags.cancelled = true
        pollTask?.cancel()
        teardownUI()
        end()
    }

    @objc private func doneTapped() {
        guard !ended, !flags.finishRequested else { return }
        flags.finishRequested = true
        teardownUI()
        // The poll task composites and calls concludeFinished.
    }

    // MARK: Called from the poll task

    func updateStatus(capturedPx: Int, hasMotion: Bool) {
        guard !uiTornDown, hasMotion else { return }
        let count = ScrollingSession.pxFormatter.string(from: NSNumber(value: capturedPx))
            ?? String(capturedPx)
        statusLabel?.stringValue = "Captured \(count) px"
    }

    /// The poll task decided to finish on its own (hard stop / page bottom) —
    /// drop the chrome right away so the user isn't staring at dead buttons
    /// while the composite builds.
    func autoFinishBegan() {
        guard !ended else { return }
        teardownUI()
    }

    func concludeFinished(with still: StillCapture?) {
        guard !ended else { return }
        teardownUI()
        if var still {
            still.origin = origin
            OutputRouter.shared.deliver(still)
        } else {
            Toast.show("Scrolling capture failed", symbol: "exclamationmark.triangle")
        }
        end()
    }

    func fail(message: String) {
        guard !ended else { return }
        teardownUI()
        Toast.show(message, symbol: "exclamationmark.triangle")
        end()
    }

    // MARK: Teardown

    private func teardownUI() {
        guard !uiTornDown else { return }
        uiTornDown = true
        hudPanel?.onEscape = nil
        hudPanel?.orderOut(nil)
        borderPanel?.orderOut(nil)
        hudPanel = nil
        borderPanel = nil
        statusLabel = nil
    }

    private func end() {
        guard !ended else { return }
        ended = true
        onEnd()
    }

    private static let pxFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    // MARK: Poll loop (off the main actor)

    nonisolated private static func run(
        rect: CGRect,
        display: SCDisplay,
        flags: ScrollingSessionFlags,
        session: ScrollingSession
    ) async {
        // Built once. The fetch re-resolves the display so the filter never
        // wraps a stale handle; empty excludingWindows arrays hit a
        // zero-samples bug, so this exact excludingApplications spelling is
        // load-bearing. Excluding our own application keeps toasts (and any
        // other of our windows that drift over the rect) out of the stitch;
        // the HUD and border are kept outside the sourceRect as well.
        let scDisplay: SCDisplay
        let ourApp: SCRunningApplication?
        do {
            let content = try await CaptureEngine.shared.shareableContent()
            scDisplay = content.displays.first { $0.displayID == display.displayID } ?? display
            let pid = ProcessInfo.processInfo.processIdentifier
            ourApp = content.applications.first { $0.processID == pid }
        } catch {
            await session.fail(message: error.localizedDescription)
            return
        }
        let filter = SCContentFilter(
            display: scDisplay,
            excludingApplications: ourApp.map { [$0] } ?? [],
            exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.captureResolution = .best
        config.sourceRect = CGRect(
            x: rect.minX - scDisplay.frame.minX,
            y: rect.minY - scDisplay.frame.minY,
            width: rect.width,
            height: rect.height
        )
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())

        let engine = ScrollingStitchEngine()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var wasAuto = false
        var zeroRun = 0
        var captureFailures = 0
        var warnedTall = false

        while !flags.cancelled, !flags.finishRequested {
            let auto = flags.autoScroll
            if auto {
                if !wasAuto {
                    // Scroll events land on the window under the cursor;
                    // ev.location alone does not retarget in every app.
                    CGWarpMouseCursorPosition(centre)
                    zeroRun = 0
                }
                postScrollEvent(at: centre)
                try? await Task.sleep(for: .milliseconds(80)) // let the scroll settle
            }
            wasAuto = auto
            if flags.cancelled || flags.finishRequested { break }

            do {
                let frame = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
                captureFailures = 0
                let outcome = await engine.process(frame)
                await session.updateStatus(
                    capturedPx: outcome.capturedPx, hasMotion: engine.hasMotion)

                if outcome.capturedPx >= ScrollingLimits.hardStopPx {
                    flags.finishRequested = true
                    await session.autoFinishBegan()
                    break
                }
                if !warnedTall, outcome.capturedPx >= ScrollingLimits.warnPx {
                    warnedTall = true
                    await MainActor.run {
                        Toast.show("Very tall capture — finishes at 60,000 px", symbol: "ruler")
                    }
                }
                if auto {
                    if outcome.matched, outcome.dyPx == 0 {
                        zeroRun += 1
                        if zeroRun >= 4 { // page bottom reached
                            flags.finishRequested = true
                            await session.autoFinishBegan()
                            break
                        }
                    } else if outcome.dyPx != 0 {
                        zeroRun = 0
                    }
                }
            } catch {
                captureFailures += 1
                if captureFailures >= 25 {
                    await session.fail(message: "Screen capture stopped responding")
                    return
                }
            }

            if flags.cancelled || flags.finishRequested { break }
            try? await Task.sleep(for: .milliseconds(auto ? 70 : 120))
        }

        if flags.cancelled { return } // session already torn down on main

        var still: StillCapture?
        if engine.hasMotion {
            if let image = engine.composite() {
                still = StillCapture(image: image, scale: scale, source: .scrolling, screenRect: nil)
            }
        } else {
            // Nothing ever scrolled — hand back a plain area shot instead of
            // failing (Done straight away is a legitimate use).
            var frame = engine.firstFrame
            if frame == nil {
                frame = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
            }
            if let frame {
                still = StillCapture(image: frame, scale: scale, source: .area, screenRect: rect)
            }
        }
        await session.concludeFinished(with: still)
    }

    nonisolated private static func postScrollEvent(at point: CGPoint) {
        // Negative wheel1 scrolls toward the page bottom in practice; if an
        // app inverts it, the stitcher just sees the resulting motion and the
        // zero-dy auto-finish still terminates.
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source, units: .pixel,
            wheelCount: 1, wheel1: -90, wheel2: 0, wheel3: 0
        ) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }
}

// MARK: - Cross-task flags

/// The only state shared between the main actor and the poll task.
private final class ScrollingSessionFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _finishRequested = false
    private var _autoScroll = false

    var cancelled: Bool {
        get { lock.withLock { _cancelled } }
        set { lock.withLock { _cancelled = newValue } }
    }
    var finishRequested: Bool {
        get { lock.withLock { _finishRequested } }
        set { lock.withLock { _finishRequested = newValue } }
    }
    var autoScroll: Bool {
        get { lock.withLock { _autoScroll } }
        set { lock.withLock { _autoScroll = newValue } }
    }
}

private enum ScrollingLimits {
    static let warnPx = 30_000
    static let hardStopPx = 60_000
}

// MARK: - Panels

private final class ScrollingHUDPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

private final class ScrollingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // 2pt accent ring 1pt clear of the capture rect's edge — the view is
        // the rect grown by 3 on each side, the stroke fills its outer 2pt.
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

// MARK: - Stitch engine (poll task only)

private struct ScrollingFrameOutcome {
    let dyPx: Int
    let matched: Bool
    let capturedPx: Int
}

/// Registration + strip bookkeeping. Owned by the poll task — single-threaded
/// by construction, so no locking.
private final class ScrollingStitchEngine {
    private struct Strip {
        let image: CGImage
        /// Document-space pixel offset of the strip's first row.
        let top: Int
    }

    // One stateful tracker instance, fed every frame in temporal order.
    private let tracker = TrackTranslationalImageRegistrationRequest()
    /// The Vision transform's sign convention is undocumented; the first real
    /// motion is cross-checked against NCC and the sign locked from then on.
    private var signCalibrated = false
    private var flipVisionSign = false

    private(set) var firstFrame: CGImage?
    private var lastFrame: CGImage?
    private var frameWidth = 0
    private var frameHeight = 0
    private var maxPlausibleDy = 0

    private var previousProfile: ScrollingFrameProfile?
    /// A dropped frame advances the tracker's internal reference past the
    /// last accepted frame, so the next Vision dy no longer measures motion
    /// relative to the stitched document; NCC against the last accepted
    /// profile covers the gap instead.
    private var previousFrameDropped = false

    private var strips: [Strip] = []
    private var cumulativeOffset = 0
    private var capturedBottom = 0

    private var headerPx = 0
    private var footerPx = 0
    private var bandsLocked = false
    private var staticTopMin = Int.max
    private var staticBottomMin = Int.max
    private var movingPairCount = 0

    private var acceptedMotionCount = 0
    var hasMotion: Bool { acceptedMotionCount > 0 }

    func process(_ frame: CGImage) async -> ScrollingFrameOutcome {
        if firstFrame == nil { return await ingestFirst(frame) }
        guard frame.width == frameWidth, frame.height == frameHeight,
              let prevProfile = previousProfile,
              let profile = ScrollingNCC.profile(of: frame)
        else {
            previousFrameDropped = true
            return ScrollingFrameOutcome(dyPx: 0, matched: false, capturedPx: capturedBottom)
        }

        var visionDy: Int?
        if let observation = try? await tracker.perform(on: frame) {
            let transform = observation.alignmentTransform
            // Pure vertical scroll: sideways drift or an implausible jump
            // means the registration latched onto the wrong feature.
            if abs(transform.tx) <= 2, abs(transform.ty) <= CGFloat(maxPlausibleDy) {
                visionDy = Int(transform.ty.rounded())
            }
        }
        if previousFrameDropped { visionDy = nil }

        var dy: Int?
        if signCalibrated {
            if let visionDy {
                dy = flipVisionSign ? -visionDy : visionDy
            } else {
                dy = ncc(prev: prevProfile, curr: profile)
            }
        } else {
            // Until calibrated, NCC is the truth and Vision only supplies the
            // sign comparison.
            let nccDy = ncc(prev: prevProfile, curr: profile)
            if let nccDy, nccDy != 0, let visionDy, visionDy != 0 {
                flipVisionSign = (nccDy < 0) != (visionDy < 0)
                signCalibrated = true
            }
            dy = nccDy
        }

        guard let dy else {
            previousFrameDropped = true
            return ScrollingFrameOutcome(dyPx: 0, matched: false, capturedPx: capturedBottom)
        }
        previousProfile = profile
        previousFrameDropped = false
        lastFrame = frame
        if dy == 0 {
            return ScrollingFrameOutcome(dyPx: 0, matched: true, capturedPx: capturedBottom)
        }

        accumulateStaticBands(prev: prevProfile, curr: profile, dy: dy)
        acceptedMotionCount += 1
        cumulativeOffset += dy
        appendNewlyRevealed(from: frame)
        return ScrollingFrameOutcome(dyPx: dy, matched: true, capturedPx: capturedBottom)
    }

    private func ingestFirst(_ frame: CGImage) async -> ScrollingFrameOutcome {
        firstFrame = frame
        lastFrame = frame
        frameWidth = frame.width
        frameHeight = frame.height
        maxPlausibleDy = Int(0.9 * Double(frameHeight))
        // The tracker's first observation is meaningless — prime and discard.
        _ = try? await tracker.perform(on: frame)
        previousProfile = ScrollingNCC.profile(of: frame)
        strips = [Strip(image: frame, top: 0)]
        cumulativeOffset = 0
        capturedBottom = frameHeight
        return ScrollingFrameOutcome(dyPx: 0, matched: true, capturedPx: frameHeight)
    }

    private func ncc(prev: ScrollingFrameProfile, curr: ScrollingFrameProfile) -> Int? {
        ScrollingNCC.verticalOffset(
            prev: prev, curr: curr,
            headerPx: headerPx, footerPx: footerPx,
            maxScroll: maxPlausibleDy
        )?.dy
    }

    /// Sticky header/footer detection: rows that barely change across moving
    /// frames are fixed chrome; exclude them from matching and from appended
    /// strips (the header survives only in the first frame). Computed once
    /// after three moving pairs, then locked.
    private func accumulateStaticBands(
        prev: ScrollingFrameProfile, curr: ScrollingFrameProfile, dy: Int
    ) {
        guard !bandsLocked, abs(dy) >= 8 else { return }
        let bands = ScrollingNCC.staticEdgeBands(prev: prev, curr: curr)
        staticTopMin = min(staticTopMin, bands.top)
        staticBottomMin = min(staticBottomMin, bands.bottom)
        movingPairCount += 1
        if movingPairCount >= 3 {
            bandsLocked = true
            // A "sticky" band deeper than a third of the frame is far more
            // likely flat page background than real chrome.
            headerPx = min(staticTopMin, frameHeight / 3)
            footerPx = min(staticBottomMin, frameHeight / 3)
        }
    }

    /// Scrolling back up only moves the offset — nothing is un-stitched. New
    /// pixels append only once the frame's usable bottom passes what has
    /// already been captured.
    private func appendNewlyRevealed(from frame: CGImage) {
        let usableBottom = frameHeight - footerPx
        let newBottomDoc = cumulativeOffset + usableBottom
        guard newBottomDoc > capturedBottom else { return }
        let stripTop = max(capturedBottom - cumulativeOffset, headerPx)
        let stripHeight = usableBottom - stripTop
        if stripHeight > 0,
           let shared = frame.cropping(
            to: CGRect(x: 0, y: stripTop, width: frameWidth, height: stripHeight)),
           let owned = ScrollingStitchEngine.copyPixels(shared) {
            // cropping(to:) shares the whole frame's backing store; copying
            // the strip lets the ~20 MB frame die with the next poll, keeping
            // memory proportional to the document, not to frames kept.
            strips.append(Strip(image: owned, top: cumulativeOffset + stripTop))
        }
        capturedBottom = newBottomDoc
    }

    func composite() -> CGImage? {
        guard frameWidth > 0, capturedBottom > 0 else { return nil }
        var allStrips = strips
        var totalHeight = capturedBottom
        // Every appended strip had the footer band cropped off; the last
        // frame supplies the one genuine copy at the document bottom — but
        // only if the user finished at the bottom, else it would stamp footer
        // pixels over good content.
        if footerPx > 0, let lastFrame,
           cumulativeOffset + (frameHeight - footerPx) == capturedBottom,
           let shared = lastFrame.cropping(to: CGRect(
            x: 0, y: frameHeight - footerPx, width: frameWidth, height: footerPx)),
           let owned = ScrollingStitchEngine.copyPixels(shared) {
            allStrips.append(Strip(image: owned, top: capturedBottom))
            totalHeight += footerPx
        }
        guard let context = CGContext(
            data: nil, width: frameWidth, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: frameWidth, height: totalHeight))
        for strip in allStrips {
            // CG contexts draw bottom-up; strip tops are from the document top.
            let y = totalHeight - strip.top - strip.image.height
            context.draw(strip.image, in: CGRect(
                x: 0, y: y, width: strip.image.width, height: strip.image.height))
        }
        return context.makeImage()
    }

    private static func copyPixels(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

// MARK: - vDSP matcher

/// Row-major grayscale column profile; row 0 is the top scanline.
private struct ScrollingFrameProfile {
    let width: Int
    let height: Int
    let px: [Float]
}

private enum ScrollingNCC {
    static func profile(of image: CGImage, sampleWidth: Int = 64) -> ScrollingFrameProfile? {
        let height = image.height
        guard height > 0, let context = CGContext(
            data: nil, width: sampleWidth, height: height,
            bitsPerComponent: 8, bytesPerRow: sampleWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var floats = [Float](repeating: 0, count: sampleWidth * height)
        vDSP_vfltu8(bytes, 1, &floats, 1, vDSP_Length(sampleWidth * height))
        return ScrollingFrameProfile(width: sampleWidth, height: height, px: floats)
    }

    /// dy > 0 = scrolled down (content moved up); dy < 0 = scrolled back up.
    /// Slides a band of the previous frame (anchored just above the footer)
    /// over the current frame; best normalised cross-correlation wins, and
    /// anything under 0.9 (animation, flat content) is a non-answer.
    static func verticalOffset(
        prev: ScrollingFrameProfile, curr: ScrollingFrameProfile,
        headerPx: Int, footerPx: Int,
        bandRows: Int = 160, maxScroll: Int
    ) -> (dy: Int, score: Float)? {
        let width = prev.width
        let height = prev.height
        guard width > 0, height > 0, curr.width == width, curr.height == height else {
            return nil
        }
        let usableEnd = height - footerPx
        let bandStart = max(headerPx, usableEnd - bandRows)
        let rows = usableEnd - bandStart
        guard rows >= 16 else { return nil }
        let count = rows * width

        var bandNorm = [Float](repeating: 0, count: count)
        var mean: Float = 0
        var sd: Float = 0
        prev.px.withUnsafeBufferPointer { buffer in
            vDSP_normalize(
                buffer.baseAddress! + bandStart * width, 1,
                &bandNorm, 1, &mean, &sd, vDSP_Length(count))
        }
        guard sd > 1e-3 else { return nil } // flat band, unmatchable

        var best: (dy: Int, score: Float) = (0, -2)
        var candidateNorm = [Float](repeating: 0, count: count)
        var dot: Float = 0
        // Small negative range = backwards scroll.
        for dy in (-maxScroll / 4)...maxScroll {
            let row = bandStart - dy // where the band lands in the current frame
            guard row >= headerPx, row + rows <= usableEnd else { continue }
            var candidateSD: Float = 0
            curr.px.withUnsafeBufferPointer { buffer in
                vDSP_normalize(
                    buffer.baseAddress! + row * width, 1,
                    &candidateNorm, 1, &mean, &candidateSD, vDSP_Length(count))
            }
            guard candidateSD > 1e-3 else { continue }
            vDSP_dotpr(bandNorm, 1, candidateNorm, 1, &dot, vDSP_Length(count))
            let score = dot / Float(count) // zero-mean unit-sd dot = Pearson r
            if score > best.score { best = (dy, score) }
        }
        return best.score >= 0.9 ? best : nil
    }

    /// Contiguous top/bottom rows whose per-row mean |diff| stays ~0 between
    /// two frames of a moving pair — sticky chrome candidates.
    static func staticEdgeBands(
        prev: ScrollingFrameProfile, curr: ScrollingFrameProfile
    ) -> (top: Int, bottom: Int) {
        let width = prev.width
        let height = min(prev.height, curr.height)
        guard width > 0, height > 0, curr.width == width else { return (0, 0) }
        var rowDiff = [Float](repeating: 0, count: height)
        var scratch = [Float](repeating: 0, count: width)
        prev.px.withUnsafeBufferPointer { prevBuffer in
            curr.px.withUnsafeBufferPointer { currBuffer in
                for row in 0..<height {
                    vDSP_vsub(
                        prevBuffer.baseAddress! + row * width, 1,
                        currBuffer.baseAddress! + row * width, 1,
                        &scratch, 1, vDSP_Length(width))
                    var meanMagnitude: Float = 0
                    vDSP_meamgv(scratch, 1, &meanMagnitude, vDSP_Length(width))
                    rowDiff[row] = meanMagnitude
                }
            }
        }
        let threshold: Float = 2.0 // antialiasing wiggle on a 0-255 scale
        var top = 0
        while top < height, rowDiff[top] < threshold { top += 1 }
        var bottom = 0
        while bottom < height - top, rowDiff[height - 1 - bottom] < threshold { bottom += 1 }
        return (top, bottom)
    }
}
