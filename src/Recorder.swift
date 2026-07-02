import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

/// Screen recording: border chrome + pre-record control strip + countdown,
/// then an SCStream + SCRecordingOutput pipeline. GIF recordings run the same
/// pipeline and convert on stop via GIFExporter.
@MainActor
final class RecordingController {
    static let shared = RecordingController()

    private enum Phase {
        case idle
        case configuring   // chrome + control strip up, nothing captured yet
        case countdown     // record pressed, digits ticking (strip still up for Esc/Cancel)
        case recording     // stream live; isRecording flips on the delegate callback
    }

    private(set) var isRecording = false
    var onStateChange: (() -> Void)?

    /// Authoritative elapsed time — capture start is async, so a wall clock
    /// started at button-press drifts ~0.5s.
    var recordedDuration: TimeInterval {
        guard let output = recordingOutput else { return 0 }
        let seconds = output.recordedDuration.seconds
        return seconds.isFinite ? seconds : 0
    }

    private var phase: Phase = .idle
    private var selection: SelectionController.Selection?
    private var asGIF = false
    private var origin: CaptureOrigin?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private let delegateProxy = RecorderDelegateProxy()

    private var borderPanel: NSPanel?
    private var borderView: RecorderBorderView?
    private var strip: RecorderControlStrip?
    private var countdownPanel: NSPanel?
    private var countdownLabel: NSTextField?
    private var countdownTask: Task<Void, Never>?
    private var userStopGraceTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    private init() {}

    // MARK: Entry points

    func start(selection: SelectionController.Selection, asGIF: Bool) {
        guard stream == nil else { return }
        // A fresh hotkey-driven selection can land while a previous strip is
        // still up — the newest intent wins.
        if phase != .idle { cancelConfiguration() }

        self.selection = selection
        self.asGIF = asGIF
        // Provenance for the record manifest, resolved while the captured
        // context is still frontmost (the control strip never activates us).
        if let window = selection.window {
            origin = CaptureOrigin(
                appBundleID: window.owningApplication?.bundleIdentifier,
                appName: window.owningApplication?.applicationName,
                windowTitle: window.title,
                displayID: selection.display.displayID)
        } else {
            origin = CaptureOrigin.frontmost(displayID: selection.display.displayID)
        }
        phase = .configuring
        showBorderChrome(around: selection.rect)
        showControlStrip(for: selection, asGIF: asGIF)
        onStateChange?()
    }

    /// Anything but idle — the record hotkey must act as "stop/cancel" for
    /// the whole configuring/countdown/spin-up window, not just once
    /// isRecording flips (which lags stream start by hundreds of ms).
    var isBusy: Bool { phase != .idle }

    func stop() {
        if phase == .configuring || phase == .countdown {
            cancelConfiguration()
            return
        }
        // Nil-guarding the stream makes stop idempotent — a second stopCapture
        // throws .attemptToStopStreamState.
        guard let stream else { return }
        self.stream = nil
        Task {
            // Finalises the file; recordingOutputDidFinishRecording follows.
            try? await stream.stopCapture()
        }
    }

    // MARK: Configure phase

    private func cancelConfiguration() {
        countdownTask?.cancel()
        countdownTask = nil
        removePanels()
        selection = nil
        phase = .idle
        onStateChange?()
    }

    private func beginCountdownAndRecord() {
        guard phase == .configuring, let selection else { return }
        phase = .countdown
        strip?.setControlsEnabled(false)   // Cancel stays live; Esc still works

        countdownTask = Task { @MainActor in
            // Ask for the mic up front so the TCC prompt never lands mid-recording.
            var micUsable = false
            if Settings.shared.recordMicrophone {
                micUsable = await AVCaptureDevice.requestAccess(for: .audio)
                if Task.isCancelled { return }
                if !micUsable {
                    Toast.show("Microphone access denied — recording without it", symbol: "mic.slash")
                }
            }
            guard self.phase == .countdown else { return }

            let total = Settings.shared.recordingCountdown
            if total > 0 {
                self.showCountdown(in: selection.rect)
                for remaining in stride(from: total, through: 1, by: -1) {
                    self.updateCountdown(remaining)
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
                self.hideCountdown()
            }
            guard self.phase == .countdown else { return }
            await self.startStream(selection: selection, micUsable: micUsable)
        }
    }

    // MARK: Stream

    private func startStream(selection: SelectionController.Selection, micUsable: Bool) async {
        hideControlStrip()
        let settings = Settings.shared

        let filter: SCContentFilter
        if let window = selection.window {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            // Exclude our whole application, not individual windows: QAO
            // cards, toasts and pins must never appear in a recording, and
            // app-level exclusion also covers windows created mid-recording.
            // (The excludingWindows: [] spelling has a known zero-samples bug
            // on some macOS builds — this overload is the safe one.)
            let pid = ProcessInfo.processInfo.processIdentifier
            let content = try? await CaptureEngine.shared.shareableContent()
            let ourApp = content?.applications.first { $0.processID == pid }
            filter = SCContentFilter(
                display: selection.display,
                excludingApplications: ourApp.map { [$0] } ?? [],
                exceptingWindows: [])
        }
        let scale = CGFloat(filter.pointPixelScale)

        let config = SCStreamConfiguration()
        if selection.window != nil {
            // sourceRect is ignored for desktopIndependentWindow filters —
            // full contentRect, no crop.
            config.width = Int(filter.contentRect.width * scale) & ~1
            config.height = Int(filter.contentRect.height * scale) & ~1
        } else {
            let local = CGRect(
                x: selection.rect.minX - selection.display.frame.minX,
                y: selection.rect.minY - selection.display.frame.minY,
                width: selection.rect.width,
                height: selection.rect.height
            )
            config.sourceRect = local
            // Even dimensions: H.264 4:2:0 subsampling can fail or pad on odd sizes.
            config.width = Int(local.width * scale) & ~1
            config.height = Int(local.height * scale) & ~1
        }

        var fps = max(1, settings.videoFPS)
        if asGIF { fps = min(fps, 30) }   // no point recording faster than GIF playback allows
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5
        config.showsCursor = settings.showCursorInRecording
        // Native click rings (macOS 15+) — no event tap, no Accessibility.
        config.showMouseClicks = settings.showClicksInRecording && settings.showCursorInRecording
        config.capturesAudio = settings.recordSystemAudio
        config.excludesCurrentProcessAudio = true
        let micOn = settings.recordMicrophone && micUsable
        config.captureMicrophone = micOn
        if micOn {
            config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sentry-capture-\(UUID().uuidString).mp4")
        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.outputFileType = .mp4
        recConfig.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recConfig, delegate: delegateProxy)
        let stream = SCStream(filter: filter, configuration: config, delegate: delegateProxy)

        // Commit state before the await: recordingOutputDidStartRecording can
        // land while startCapture is still suspended.
        recordingOutput = output
        outputURL = url
        phase = .recording

        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            try? await stream.stopCapture()
            if !(error is CancellationError) {
                finishSession(error: error)
            }
            return
        }
        if Task.isCancelled {
            // A newer session took over while capture was spinning up.
            try? await stream.stopCapture()
            return
        }

        self.stream = stream
        borderView?.colour = .systemRed
        observeScreenChanges()
    }

    // MARK: Delegate arrivals (proxy hops to main, then here)

    fileprivate func handleRecordingStarted(_ output: SCRecordingOutput) {
        guard output === recordingOutput, phase == .recording else { return }
        isRecording = true
        onStateChange?()
    }

    fileprivate func handleRecordingFailed(_ output: SCRecordingOutput, error: Error) {
        guard output === recordingOutput else { return }
        finishSession(error: error)
    }

    fileprivate func handleRecordingFinished(_ output: SCRecordingOutput) {
        guard output === recordingOutput else { return }
        userStopGraceTask?.cancel()
        userStopGraceTask = nil
        finishSession(error: nil)
    }

    fileprivate func handleStreamStopped(error: Error) {
        stream = nil
        let nsError = error as NSError
        let userStopped = nsError.domain == SCStreamErrorDomain
            && SCStreamError.Code(rawValue: nsError.code) == .userStopped
        if userStopped {
            // Stop via the system's purple indicator: the output usually
            // finalises right after — wait for didFinishRecording so we do
            // not deliver a half-written mp4. Long recordings can take
            // seconds to write the moov atom, hence the generous timeout.
            guard userStopGraceTask == nil else { return }
            userStopGraceTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self.userStopGraceTask = nil
                self.finishSession(error: nil)
            }
        } else {
            finishSession(error: error)
        }
    }

    // MARK: The one terminal path

    /// Every way a recording ends — finished, failed, stream died — lands here
    /// exactly once (the phase guard swallows duplicate delegate callbacks).
    private func finishSession(error: Error?) {
        guard phase == .recording else { return }
        phase = .idle

        // A failed recording output can leave the stream running.
        if let stream {
            self.stream = nil
            Task { try? await stream.stopCapture() }
        }
        userStopGraceTask?.cancel()
        userStopGraceTask = nil
        countdownTask = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        removePanels()

        let wasGIF = asGIF
        let url = outputURL
        let capturedOrigin = origin
        let duration = recordedDuration
        origin = nil
        recordingOutput = nil
        outputURL = nil
        selection = nil
        isRecording = false
        onStateChange?()

        if let error {
            Toast.show("Recording failed: \(error.localizedDescription)",
                       symbol: "exclamationmark.triangle")
            if let url { try? FileManager.default.removeItem(at: url) }
            return
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            Toast.show("Recording produced no file", symbol: "exclamationmark.triangle")
            return
        }

        if wasGIF {
            Task { @MainActor in
                // CGImageDestination holds every frame until finalise — an
                // unbounded GIF balloons into gigabytes. Past two minutes,
                // keep the MP4 instead of pretending.
                let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                guard seconds <= 120 else {
                    Toast.show("Recording too long for a GIF — saved as MP4",
                               symbol: "exclamationmark.triangle")
                    OutputRouter.shared.deliver(VideoCapture(
                        url: url, isGIF: false, origin: capturedOrigin, durationSeconds: duration))
                    return
                }
                Toast.show("Converting to GIF…", symbol: "arrow.triangle.2.circlepath")
                do {
                    let gif = try await GIFExporter.export(
                        from: url, fps: Settings.shared.gifFPS, maxWidth: 1000)
                    try? FileManager.default.removeItem(at: url)
                    OutputRouter.shared.deliver(VideoCapture(
                        url: gif, isGIF: true, origin: capturedOrigin, durationSeconds: duration))
                } catch {
                    // Keep the mp4 rather than lose the recording.
                    Toast.show("GIF conversion failed — saving as MP4",
                               symbol: "exclamationmark.triangle")
                    OutputRouter.shared.deliver(VideoCapture(
                        url: url, isGIF: false, origin: capturedOrigin, durationSeconds: duration))
                }
            }
        } else {
            OutputRouter.shared.deliver(VideoCapture(
                url: url, isGIF: false, origin: capturedOrigin, durationSeconds: duration))
        }
    }

    // MARK: Display lifecycle

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording,
                      let displayID = self.selection?.display.displayID else { return }
                // Finalise ourselves before SCK errors out with a dead display.
                if !NSScreen.screens.contains(where: { $0.displayID == displayID }) {
                    self.stop()
                }
            }
        }
    }

    // MARK: Border chrome

    private func showBorderChrome(around rect: CGRect) {
        // Inflated so the stroke sits wholly outside the recorded rect — the
        // area filter excludes nothing, so anything inside would be recorded.
        let inflated = rect.insetBy(
            dx: -RecorderBorderView.strokeWidth, dy: -RecorderBorderView.strokeWidth)
        let panel = NSPanel(
            contentRect: Coords.appKitRect(fromCG: inflated),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        let view = RecorderBorderView()
        panel.contentView = view
        panel.orderFrontRegardless()
        borderPanel = panel
        borderView = view
    }

    // MARK: Control strip

    private func showControlStrip(for selection: SelectionController.Selection, asGIF: Bool) {
        let sizeText = "\(Int(selection.rect.width)) × \(Int(selection.rect.height))"
        let strip = RecorderControlStrip(sizeText: sizeText, asGIF: asGIF)
        strip.onCancel = { [weak self] in self?.cancelConfiguration() }
        strip.onRecord = { [weak self] in self?.beginCountdownAndRecord() }
        strip.onFormatChange = { [weak self] gif in self?.asGIF = gif }

        let size = strip.frame.size
        let display = selection.display.frame
        let gap: CGFloat = 12
        // CG top-left space: below the selection = larger y.
        var origin = CGPoint(x: selection.rect.midX - size.width / 2,
                             y: selection.rect.maxY + gap)
        if origin.y + size.height > display.maxY - 8 {
            origin.y = selection.rect.minY - gap - size.height
        }
        origin.y = max(origin.y, display.minY + 8)
        origin.x = min(max(origin.x, display.minX + 8), display.maxX - size.width - 8)
        strip.setFrame(
            Coords.appKitRect(fromCG: CGRect(origin: origin, size: size)), display: false)

        strip.alphaValue = 0
        strip.makeKeyAndOrderFront(nil)   // key (canBecomeKey) so Esc reaches us; app stays inactive
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            strip.animator().alphaValue = 1
        }
        self.strip = strip
    }

    private func hideControlStrip() {
        strip?.orderOut(nil)
        strip = nil
    }

    // MARK: Countdown

    private func showCountdown(in rect: CGRect) {
        let panel = NSPanel(
            contentRect: Coords.appKitRect(fromCG: rect),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none

        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(
            ofSize: min(140, max(48, rect.height * 0.35)), weight: .thin)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.alignment = .center
        label.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 12
        label.shadow = shadow

        let content = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.contentView = content
        panel.orderFrontRegardless()

        countdownPanel = panel
        countdownLabel = label
    }

    private func updateCountdown(_ remaining: Int) {
        guard let label = countdownLabel else { return }
        label.stringValue = "\(remaining)"
        label.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            label.animator().alphaValue = 1
        }
    }

    private func hideCountdown() {
        countdownPanel?.orderOut(nil)
        countdownPanel = nil
        countdownLabel = nil
    }

    private func removePanels() {
        hideControlStrip()
        hideCountdown()
        borderPanel?.orderOut(nil)
        borderPanel = nil
        borderView = nil
    }
}

// MARK: - Delegate proxy

/// SCStream/SCRecordingOutput callbacks arrive on an internal queue; this
/// nonisolated shim hops them onto the main actor.
private final class RecorderDelegateProxy: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            RecordingController.shared.handleRecordingStarted(recordingOutput)
        }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            RecordingController.shared.handleRecordingFailed(recordingOutput, error: error)
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            RecordingController.shared.handleRecordingFinished(recordingOutput)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            RecordingController.shared.handleStreamStopped(error: error)
        }
    }
}

// MARK: - Border chrome view

@MainActor
private final class RecorderBorderView: NSView {
    static let strokeWidth: CGFloat = 2

    var colour: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Square corners: a rounded stroke's corner arcs intrude into the
        // recorded rect (the panel is inflated by exactly one stroke width),
        // baking coloured slivers into every recording corner.
        let inset = Self.strokeWidth / 2
        let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
        path.lineWidth = Self.strokeWidth
        colour.setStroke()
        path.stroke()
    }
}

// MARK: - Control strip panel

@MainActor
private final class RecorderControlStrip: NSPanel {
    var onCancel: (() -> Void)?
    var onRecord: (() -> Void)?
    var onFormatChange: ((Bool) -> Void)?

    private var format: NSSegmentedControl!
    private var audioToggle: NSButton!
    private var micToggle: NSButton!
    private var cursorToggle: NSButton!
    private var recordButton: NSButton!
    private var cancelButton: NSButton!

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(sizeText: String, asGIF: Bool) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        animationBehavior = .none
        build(sizeText: sizeText, asGIF: asGIF)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Countdown running: config is committed, only Cancel (and Esc) stay live.
    func setControlsEnabled(_ enabled: Bool) {
        format.isEnabled = enabled
        audioToggle.isEnabled = enabled
        micToggle.isEnabled = enabled
        cursorToggle.isEnabled = enabled
        recordButton.isEnabled = enabled
    }

    private func build(sizeText: String, asGIF: Bool) {
        let sizeLabel = NSTextField(labelWithString: sizeText)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = .secondaryLabelColor

        format = NSSegmentedControl(
            labels: ["MP4", "GIF"], trackingMode: .selectOne,
            target: self, action: #selector(formatChanged))
        format.selectedSegment = asGIF ? 1 : 0
        format.controlSize = .small
        format.font = .systemFont(ofSize: 11, weight: .medium)

        audioToggle = toggle(
            symbol: "speaker.wave.2", tip: "System Audio",
            isOn: Settings.shared.recordSystemAudio, action: #selector(audioToggled(_:)))
        micToggle = toggle(
            symbol: "mic", tip: "Microphone",
            isOn: Settings.shared.recordMicrophone, action: #selector(micToggled(_:)))
        cursorToggle = toggle(
            symbol: "cursorarrow", tip: "Cursor",
            isOn: Settings.shared.showCursorInRecording, action: #selector(cursorToggled(_:)))

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular

        recordButton = NSButton(title: "Record", target: self, action: #selector(recordPressed))
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .regular
        recordButton.keyEquivalent = "\r"
        recordButton.bezelColor = .controlAccentColor

        let stack = NSStackView(views: [
            sizeLabel, hairline(),
            format, hairline(),
            audioToggle, micToggle, cursorToggle, hairline(),
            cancelButton, recordButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 12)

        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.state = .active
        // The HUD card stays dark regardless of the system appearance; pin the
        // effective appearance so label colours resolve for dark.
        card.appearance = NSAppearance(named: .vibrantDark)
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
        contentView = card
        setContentSize(stack.fittingSize)
    }

    private func toggle(symbol: String, tip: String, isOn: Bool, action: Selector) -> NSButton {
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let image = base.withSymbolConfiguration(
            .init(pointSize: 13, weight: .medium)) ?? base
        let button = NSButton(image: image, target: self, action: action)
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        button.toolTip = tip
        button.state = isOn ? .on : .off
        tint(button)
        return button
    }

    private func tint(_ button: NSButton) {
        button.contentTintColor = button.state == .on ? .controlAccentColor : .tertiaryLabelColor
    }

    private func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 18),
        ])
        return line
    }

    @objc private func formatChanged() {
        onFormatChange?(format.selectedSegment == 1)
    }

    @objc private func audioToggled(_ sender: NSButton) {
        Settings.shared.recordSystemAudio = sender.state == .on
        tint(sender)
    }

    @objc private func micToggled(_ sender: NSButton) {
        Settings.shared.recordMicrophone = sender.state == .on
        tint(sender)
    }

    @objc private func cursorToggled(_ sender: NSButton) {
        Settings.shared.showCursorInRecording = sender.state == .on
        tint(sender)
    }

    @objc private func cancelPressed() {
        onCancel?()
    }

    @objc private func recordPressed() {
        onRecord?()
    }
}
