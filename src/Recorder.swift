import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

/// Screen recording: border chrome + pre-record control strip + countdown,
/// then an SCStream feeding a RecordingWriter (AVAssetWriter) — the writer
/// path exists so recordings can pause/resume. GIF recordings run the same
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
    private(set) var isPaused = false
    var onStateChange: (() -> Void)?

    /// Authoritative elapsed time: what the writer has actually appended —
    /// paused stretches don't count, and capture start is async so a wall
    /// clock started at button-press drifts ~0.5s.
    var recordedDuration: TimeInterval {
        writerEngine?.elapsedSeconds ?? 0
    }

    private var phase: Phase = .idle
    private var selection: SelectionController.Selection?
    private var asGIF = false
    private var origin: CaptureOrigin?

    private var stream: SCStream?
    private var writerEngine: RecordingWriter?
    private var outputURL: URL?
    private let delegateProxy = RecorderDelegateProxy()
    private var recordingHUD: RecordingHUDPanel?
    /// Keystroke HUD + webcam bubble — area recordings only (a window filter
    /// can't capture other windows, so overlays are invisible there).
    private var overlays: RecordingOverlays?

    private var borderPanel: NSPanel?
    private var borderView: RecorderBorderView?
    private var strip: RecorderControlStrip?
    private var countdownPanel: NSPanel?
    private var countdownLabel: NSTextField?
    private var countdownTask: Task<Void, Never>?
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
        if Settings.shared.showWebcamInRecording {
            // Up during configuration so the user can place it before recording.
            ensureOverlays()?.showWebcam()
        }
        if Settings.shared.hideDesktopWhileRecording {
            ensureOverlays()?.showDesktopCover()
        }
        onStateChange?()
    }

    private func ensureOverlays() -> RecordingOverlays? {
        guard let selection, selection.window == nil else { return nil }
        if overlays == nil { overlays = RecordingOverlays(rect: selection.rect) }
        return overlays
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
        Task { @MainActor in
            // No delegate callback follows a stop we initiated — finalise the
            // writer ourselves.
            try? await stream.stopCapture()
            self.finishSession(error: nil)
        }
    }

    /// Pause holds the file open while the writer drops frames; resume stitches
    /// the timeline back together. Recording time excludes the hole.
    func togglePause() {
        guard phase == .recording, let writerEngine else { return }
        isPaused.toggle()
        writerEngine.setPaused(isPaused)
        borderView?.colour = isPaused ? .systemOrange : .systemRed
        recordingHUD?.setPaused(isPaused)
        onStateChange?()
    }

    /// Stop and throw the file away — for the take that went wrong.
    func discardRecording() {
        guard phase == .recording else { return }
        discardOnFinish = true
        stop()
    }
    private var discardOnFinish = false

    // MARK: Configure phase

    private func cancelConfiguration() {
        countdownTask?.cancel()
        countdownTask = nil
        removePanels()
        overlays?.teardown()
        overlays = nil
        selection = nil
        phase = .idle
        onStateChange?()
    }

    private func beginCountdownAndRecord() {
        guard phase == .configuring, let selection else { return }
        phase = .countdown
        strip?.setControlsEnabled(false)   // Cancel stays live; Esc still works

        countdownTask = Task { @MainActor in
            // Permission prompts land up front, never mid-recording.
            if Settings.shared.showKeystrokesInRecording, selection.window == nil,
               !RecordingOverlays.accessibilityTrusted(prompt: true) {
                Toast.show("Grant Accessibility to show keystrokes — recording without them",
                           symbol: "keyboard")
            }
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
        // The pause/stop HUD exists BEFORE the shareable-content fetch below so
        // the window-level exclusion path snapshots it into the excluded list —
        // it must never appear in the recording.
        showRecordingHUD(for: selection)
        if settings.showCursorHalo, selection.window == nil {
            ensureOverlays()?.showCursorHalo()
        }
        // And the webcam bubble must ALSO exist by then, for the opposite
        // reason: its window has to be findable so the filter can leave it
        // capturable — a bubble that spawns after the snapshot vanishes from
        // the video (camera permission makes its creation async).
        await overlays?.settle()

        let filter: SCContentFilter
        if let window = selection.window {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            let pid = ProcessInfo.processInfo.processIdentifier
            let content = try? await CaptureEngine.shared.shareableContent()
            let overlayNumbers = overlays?.windowNumbers ?? []
            let keystrokesOn = settings.showKeystrokesInRecording
                && RecordingOverlays.accessibilityTrusted(prompt: false)
            if overlayNumbers.isEmpty, !keystrokesOn {
                // Exclude our whole application, not individual windows: QAO
                // cards, toasts and pins must never appear in a recording, and
                // app-level exclusion also covers windows created mid-recording.
                // (The excludingWindows: [] spelling has a known zero-samples bug
                // on some macOS builds — this overload is the safe one.)
                let ourApp = content?.applications.first { $0.processID == pid }
                filter = SCContentFilter(
                    display: selection.display,
                    excludingApplications: ourApp.map { [$0] } ?? [],
                    exceptingWindows: [])
            } else {
                // Overlays must APPEAR in the recording, so exclusion drops to
                // window level: everything of ours except the overlay panels.
                // The keystroke HUD is created mid-recording — window-level
                // exclusion is a fixed list, so later windows are capturable.
                // Trade-off: a toast fired mid-recording would be captured too
                // (rare — capture hotkeys are gated while recording).
                let ours = content?.windows.filter {
                    $0.owningApplication?.processID == pid
                        && !overlayNumbers.contains($0.windowID)
                } ?? []
                if ours.isEmpty {
                    // Never pass an empty excludingWindows (zero-samples bug).
                    filter = SCContentFilter(
                        display: selection.display,
                        excludingApplications: [], exceptingWindows: [])
                } else {
                    filter = SCContentFilter(display: selection.display, excludingWindows: ours)
                }
            }
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
        let engine: RecordingWriter
        do {
            engine = try RecordingWriter(
                url: url, width: config.width, height: config.height, fps: fps,
                systemAudio: config.capturesAudio, microphone: micOn)
        } catch {
            phase = .recording   // finishSession's guard expects it
            finishSession(error: error)
            return
        }
        engine.onStarted = { [weak engine] in
            Task { @MainActor in
                guard let engine else { return }
                RecordingController.shared.handleWriterStarted(engine)
            }
        }
        engine.onFailed = { [weak engine] error in
            Task { @MainActor in
                guard let engine else { return }
                RecordingController.shared.handleWriterFailed(engine, error: error)
            }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: delegateProxy)

        // Commit state before the await: the first frame can land while
        // startCapture is still suspended.
        writerEngine = engine
        outputURL = url
        phase = .recording

        do {
            try stream.addStreamOutput(engine, type: .screen, sampleHandlerQueue: engine.queue)
            if config.capturesAudio {
                try stream.addStreamOutput(engine, type: .audio, sampleHandlerQueue: engine.queue)
            }
            if micOn {
                try stream.addStreamOutput(engine, type: .microphone, sampleHandlerQueue: engine.queue)
            }
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
        if settings.showKeystrokesInRecording, selection.window == nil {
            ensureOverlays()?.startKeystrokes()
        }
        observeScreenChanges()
    }

    // MARK: Writer + stream arrivals (hopped to main, then here)

    fileprivate func handleWriterStarted(_ engine: RecordingWriter) {
        guard engine === writerEngine, phase == .recording else { return }
        isRecording = true
        onStateChange?()
    }

    fileprivate func handleWriterFailed(_ engine: RecordingWriter, error: Error) {
        guard engine === writerEngine else { return }
        finishSession(error: error)
    }

    fileprivate func handleStreamStopped(error: Error) {
        stream = nil
        let nsError = error as NSError
        let userStopped = nsError.domain == SCStreamErrorDomain
            && SCStreamError.Code(rawValue: nsError.code) == .userStopped
        // We own file finalisation now (the writer), so a stop from the
        // system's purple indicator and a genuine failure both land in the
        // same terminal path — the writer flushes whatever it appended.
        finishSession(error: userStopped ? nil : error)
    }

    // MARK: The one terminal path

    /// Every way a recording ends — stopped, failed, stream died — lands here
    /// exactly once (the phase guard swallows duplicate callbacks). The writer
    /// finalises asynchronously; delivery waits for it.
    private func finishSession(error: Error?) {
        guard phase == .recording else { return }
        phase = .idle

        // A failed writer can leave the stream running.
        if let stream {
            self.stream = nil
            Task { try? await stream.stopCapture() }
        }
        countdownTask = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        removePanels()
        overlays?.teardown()
        overlays = nil

        let wasGIF = asGIF
        let url = outputURL
        let capturedOrigin = origin
        let engine = writerEngine
        let discard = discardOnFinish
        origin = nil
        writerEngine = nil
        outputURL = nil
        selection = nil
        isRecording = false
        isPaused = false
        discardOnFinish = false
        onStateChange?()

        if discard {
            Task {
                _ = try? await engine?.finish()
                if let url { try? FileManager.default.removeItem(at: url) }
                Toast.show("Recording discarded", symbol: "trash")
            }
            return
        }

        if let error {
            Toast.show("Recording failed: \(error.localizedDescription)",
                       symbol: "exclamationmark.triangle")
            Task {
                _ = try? await engine?.finish()
                if let url { try? FileManager.default.removeItem(at: url) }
            }
            return
        }
        guard let url, let engine else {
            Toast.show("Recording produced no file", symbol: "exclamationmark.triangle")
            return
        }

        Task { @MainActor in
            let duration: Double
            do {
                duration = try await engine.finish()
            } catch {
                Toast.show("Recording failed: \(error.localizedDescription)",
                           symbol: "exclamationmark.triangle")
                try? FileManager.default.removeItem(at: url)
                return
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                Toast.show("Recording produced no file", symbol: "exclamationmark.triangle")
                return
            }
            if wasGIF {
                // CGImageDestination holds every frame until finalise — an
                // unbounded GIF balloons into gigabytes. Past two minutes,
                // keep the MP4 instead of pretending.
                guard duration <= 120 else {
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
            } else {
                OutputRouter.shared.deliver(VideoCapture(
                    url: url, isGIF: false, origin: capturedOrigin, durationSeconds: duration))
            }
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
        strip.onWebcamChange = { [weak self] on in
            if on {
                self?.ensureOverlays()?.showWebcam()
            } else {
                self?.overlays?.hideWebcam()
            }
        }
        strip.onHaloChange = { [weak self] on in
            if on {
                self?.ensureOverlays()?.showCursorHalo()
            } else {
                self?.overlays?.hideCursorHalo()
            }
        }
        strip.onDesktopChange = { [weak self] on in
            if on {
                self?.ensureOverlays()?.showDesktopCover()
            } else {
                self?.overlays?.hideDesktopCover()
            }
        }

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
        recordingHUD?.orderOut(nil)
        recordingHUD = nil
        borderPanel?.orderOut(nil)
        borderPanel = nil
        borderView = nil
    }

    // MARK: Recording HUD (elapsed · pause · stop)

    private func showRecordingHUD(for selection: SelectionController.Selection) {
        guard recordingHUD == nil else { return }
        let hud = RecordingHUDPanel(
            displayFrameCG: selection.display.frame,
            stopHint: Settings.shared.hotkey(for: asGIF ? .recordGIF : .recordVideo)?.display,
            pauseHint: Settings.shared.hotkey(for: .pauseRecording)?.display,
            onPause: { RecordingController.shared.togglePause() },
            onStop: { RecordingController.shared.stop() },
            onDiscard: { RecordingController.shared.discardRecording() })
        hud.orderFrontRegardless()
        recordingHUD = hud
    }
}

// MARK: - Delegate proxy

/// SCStream callbacks arrive on an internal queue; this nonisolated shim hops
/// them onto the main actor.
private final class RecorderDelegateProxy: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            RecordingController.shared.handleStreamStopped(error: error)
        }
    }
}

// MARK: - Recording HUD

/// Action bar shown while recording — Zoom-style, top-centre of the recorded
/// display: elapsed time, then Pause / Stop / Discard with their keyboard
/// shortcuts spelled out. Draggable; created before the content filter is
/// built so it never appears in the video.
@MainActor
private final class RecordingHUDPanel: NSPanel {
    private let onPause: () -> Void
    private let onStop: () -> Void
    private let onDiscard: () -> Void
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let dot = NSView()
    private var pauseIcon: NSImageView!
    private var pauseTitle: NSTextField!
    private var timer: Timer?

    init(
        displayFrameCG: CGRect, stopHint: String?, pauseHint: String?,
        onPause: @escaping () -> Void, onStop: @escaping () -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.onPause = onPause
        self.onStop = onStop
        self.onDiscard = onDiscard
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        elapsedLabel.textColor = .white

        /// icon · title · greyed shortcut hint, all one clickable unit.
        func actionItem(
            symbol: String, title: String, hint: String?, tint: NSColor,
            action: Selector
        ) -> (NSView, NSImageView, NSTextField) {
            let icon = NSImageView(image: NSImage(
                systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) ?? NSImage())
            icon.contentTintColor = tint
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            var views: [NSView] = [icon, label]
            if let hint {
                let hintLabel = NSTextField(labelWithString: hint)
                hintLabel.font = .systemFont(ofSize: 11, weight: .regular)
                hintLabel.textColor = NSColor.white.withAlphaComponent(0.45)
                views.append(hintLabel)
            }
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 5
            let wrapper = HUDActionView()
            wrapper.onClick = { [weak self] in
                guard let self else { return }
                self.perform(action)
            }
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            stack.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 5),
                stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -5),
            ])
            return (wrapper, icon, label)
        }

        let (pauseView, pauseIcon, pauseTitle) = actionItem(
            symbol: "pause.fill", title: "Pause", hint: pauseHint,
            tint: .white, action: #selector(pauseTapped))
        self.pauseIcon = pauseIcon
        self.pauseTitle = pauseTitle
        let (stopView, _, _) = actionItem(
            symbol: "stop.fill", title: "Stop", hint: stopHint,
            tint: .systemRed, action: #selector(stopTapped))
        let (discardView, _, _) = actionItem(
            symbol: "trash", title: "Discard", hint: nil,
            tint: NSColor.white.withAlphaComponent(0.7), action: #selector(discardTapped))

        func hairline() -> NSView {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            line.widthAnchor.constraint(equalToConstant: 1).isActive = true
            line.heightAnchor.constraint(equalToConstant: 16).isActive = true
            return line
        }

        let stack = NSStackView(views: [
            dot, elapsedLabel, hairline(), pauseView, stopView, hairline(), discardView,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(10, after: dot)
        stack.setCustomSpacing(10, after: elapsedLabel)
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)

        let card = HUDStyle.card(appearance: .vibrantDark)
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
        let display = Coords.appKitRect(fromCG: displayFrameCG)
        let visibleTop = (NSScreen.screens.first {
            $0.frame.intersects(display)
        }?.visibleFrame.maxY) ?? display.maxY
        setFrame(
            NSRect(x: display.midX - size.width / 2, y: visibleTop - size.height - 12,
                   width: size.width, height: size.height),
            display: false)

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let seconds = Int(RecordingController.shared.recordedDuration.rounded())
                self.elapsedLabel.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
            }
        }
    }

    func setPaused(_ paused: Bool) {
        dot.layer?.backgroundColor =
            (paused ? NSColor.systemOrange : .systemRed).cgColor
        pauseIcon.image = NSImage(
            systemSymbolName: paused ? "play.fill" : "pause.fill",
            accessibilityDescription: paused ? "Resume" : "Pause")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        pauseTitle.stringValue = paused ? "Resume" : "Pause"
    }

    override func orderOut(_ sender: Any?) {
        timer?.invalidate()
        timer = nil
        super.orderOut(sender)
    }

    @objc private func pauseTapped() { onPause() }
    @objc private func stopTapped() { onStop() }
    @objc private func discardTapped() { onDiscard() }
}

/// Clickable hover-washed region for a HUD action group.
@MainActor
private final class HUDActionView: NSView {
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
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
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}

// MARK: - Border chrome view

@MainActor
private final class RecorderBorderView: NSView {
    static let strokeWidth: CGFloat = 2

    var colour: NSColor = HUDStyle.accent {
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
    var onWebcamChange: ((Bool) -> Void)?
    var onHaloChange: ((Bool) -> Void)?
    var onDesktopChange: ((Bool) -> Void)?

    private var format: NSSegmentedControl!
    private var audioToggle: NSButton!
    private var micToggle: NSButton!
    private var cursorToggle: NSButton!
    private var keysToggle: NSButton!
    private var webcamToggle: NSButton!
    private var haloToggle: NSButton!
    private var desktopToggle: NSButton!
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
        keysToggle.isEnabled = enabled
        webcamToggle.isEnabled = enabled
        haloToggle.isEnabled = enabled
        desktopToggle.isEnabled = enabled
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
        keysToggle = toggle(
            symbol: "keyboard", tip: "Show Keystrokes",
            isOn: Settings.shared.showKeystrokesInRecording, action: #selector(keysToggled(_:)))
        webcamToggle = toggle(
            symbol: "video", tip: "Webcam Bubble",
            isOn: Settings.shared.showWebcamInRecording, action: #selector(webcamToggled(_:)))
        haloToggle = toggle(
            symbol: "cursorarrow.rays", tip: "Cursor Halo",
            isOn: Settings.shared.showCursorHalo, action: #selector(haloToggled(_:)))
        desktopToggle = toggle(
            symbol: "menubar.dock.rectangle", tip: "Hide Desktop Icons",
            isOn: Settings.shared.hideDesktopWhileRecording, action: #selector(desktopToggled(_:)))

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular

        recordButton = NSButton(title: "Record", target: self, action: #selector(recordPressed))
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .regular
        recordButton.keyEquivalent = "\r"
        recordButton.bezelColor = HUDStyle.accentDeep

        let stack = NSStackView(views: [
            sizeLabel, hairline(),
            format, hairline(),
            audioToggle, micToggle, cursorToggle, keysToggle, webcamToggle,
            haloToggle, desktopToggle, hairline(),
            cancelButton, recordButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 12)

        // Pinned dark appearance so label colours resolve for dark regardless
        // of the system theme.
        let card = HUDStyle.card(appearance: .vibrantDark)

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
        button.contentTintColor = button.state == .on ? HUDStyle.accent : .tertiaryLabelColor
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

    @objc private func keysToggled(_ sender: NSButton) {
        Settings.shared.showKeystrokesInRecording = sender.state == .on
        tint(sender)
    }

    @objc private func webcamToggled(_ sender: NSButton) {
        Settings.shared.showWebcamInRecording = sender.state == .on
        tint(sender)
        onWebcamChange?(sender.state == .on)
    }

    @objc private func haloToggled(_ sender: NSButton) {
        Settings.shared.showCursorHalo = sender.state == .on
        tint(sender)
        onHaloChange?(sender.state == .on)
    }

    @objc private func desktopToggled(_ sender: NSButton) {
        Settings.shared.hideDesktopWhileRecording = sender.state == .on
        tint(sender)
        onDesktopChange?(sender.state == .on)
    }

    @objc private func cancelPressed() {
        onCancel?()
    }

    @objc private func recordPressed() {
        onRecord?()
    }
}
