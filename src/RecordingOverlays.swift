@preconcurrency import AVFoundation
import AppKit
import ApplicationServices

/// In-recording overlays: the keystroke HUD and the webcam bubble. Unlike
/// every other panel in the app these must APPEAR in the recording, so while
/// either is active the Recorder swaps its app-level exclusion for a
/// window-level one that leaves these panels capturable.
@MainActor
final class RecordingOverlays {
    /// The recorded rect, global CG top-left points — overlays position inside it.
    private let rect: CGRect

    private var webcamPanel: WebcamBubblePanel?
    private var keystrokePanel: KeystrokeHUDPanel?
    private var keyMonitor: Any?

    init(rect: CGRect) {
        self.rect = rect
    }

    /// Window numbers the Recorder's exclusion list must NOT contain.
    var windowNumbers: Set<CGWindowID> {
        var numbers: Set<CGWindowID> = []
        if let webcamPanel { numbers.insert(CGWindowID(webcamPanel.windowNumber)) }
        if let keystrokePanel { numbers.insert(CGWindowID(keystrokePanel.windowNumber)) }
        return numbers
    }

    var isEmpty: Bool { webcamPanel == nil && keystrokePanel == nil && keyMonitor == nil }

    func teardown() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        keystrokePanel?.orderOut(nil)
        keystrokePanel = nil
        hideWebcam()
    }

    // MARK: Webcam bubble

    /// Asks for camera access on first use; shows nothing when denied.
    func showWebcam() {
        guard webcamPanel == nil else { return }
        Task { @MainActor in
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                Toast.show("Camera access denied — recording without the bubble",
                           symbol: "video.slash")
                Settings.shared.showWebcamInRecording = false
                return
            }
            guard self.webcamPanel == nil else { return }
            guard let panel = WebcamBubblePanel(in: self.rect) else {
                Toast.show("No camera found", symbol: "video.slash")
                Settings.shared.showWebcamInRecording = false
                return
            }
            self.webcamPanel = panel
            panel.orderFrontRegardless()
        }
    }

    func hideWebcam() {
        webcamPanel?.stop()
        webcamPanel?.orderOut(nil)
        webcamPanel = nil
    }

    // MARK: Keystroke HUD

    /// Global key monitoring needs Accessibility; prompting is the caller's
    /// decision (record start prompts, later checks stay silent).
    static func accessibilityTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func startKeystrokes() {
        guard keyMonitor == nil, Self.accessibilityTrusted(prompt: false) else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) }
        }
    }

    private func handleKey(_ event: NSEvent) {
        if keystrokePanel == nil {
            keystrokePanel = KeystrokeHUDPanel(in: rect)
        }
        keystrokePanel?.show(event)
    }
}

// MARK: - Webcam bubble panel

/// Circular live camera preview, bottom-right of the recorded rect, draggable
/// anywhere. Deliberately clickable (not click-through) so it can be moved.
@MainActor
private final class WebcamBubblePanel: NSPanel {
    private static let side: CGFloat = 160

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "webcam-bubble", qos: .userInitiated)

    init?(in rect: CGRect) {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }

        let inset: CGFloat = 16
        let cgOrigin = CGPoint(
            x: rect.maxX - Self.side - inset,
            y: rect.maxY - Self.side - inset)
        let frame = Coords.appKitRect(
            fromCG: CGRect(origin: cgOrigin, size: CGSize(width: Self.side, height: Self.side)))
        super.init(
            contentRect: frame,
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

        session.sessionPreset = .medium
        session.addInput(input)

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = content.bounds
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = Self.side / 2
        preview.masksToBounds = true
        preview.borderWidth = 2
        preview.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        // Mirrored like every facetime-style self-view.
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        content.layer?.addSublayer(preview)
        contentView = content

        // startRunning blocks for camera spin-up — never on main.
        let session = self.session
        sessionQueue.async { session.startRunning() }
    }

    func stop() {
        let session = self.session
        sessionQueue.async { session.stopRunning() }
    }
}

// MARK: - Keystroke HUD panel

/// Dark pill above the bottom edge of the recorded rect showing what is being
/// typed: plain typing accumulates, modifier combos show as chips, and the
/// pill fades out after a beat of silence.
@MainActor
private final class KeystrokeHUDPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let anchor: CGPoint   // bottom-centre of the recorded rect, CG points
    private var buffer = ""
    private var bufferIsTyping = false
    private var fadeTask: Task<Void, Never>?

    init(in rect: CGRect) {
        anchor = CGPoint(x: rect.midX, y: rect.maxY - 24)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        card.layer?.cornerRadius = 8
        label.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        contentView = card
    }

    func show(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let hasChord = mods.contains(.command) || mods.contains(.control) || mods.contains(.option)
        if hasChord {
            buffer = glyphs(mods) + Hotkey.keyName(for: UInt32(event.keyCode))
            bufferIsTyping = false
        } else if let text = printable(event) {
            if !bufferIsTyping { buffer = "" }
            bufferIsTyping = true
            buffer += text
            if buffer.count > 18 { buffer = String(buffer.suffix(18)) }
        } else {
            buffer = Hotkey.keyName(for: UInt32(event.keyCode))
            bufferIsTyping = false
        }
        render()
    }

    /// Characters worth accumulating as typed text; nil sends the key down
    /// the named-key path (⌫, ⎋, arrows, …).
    private func printable(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty,
              let scalar = chars.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F,
              // Private-use area = function/arrow keys on macOS.
              !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        return chars
    }

    private func glyphs(_ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s
    }

    private func render() {
        label.stringValue = buffer
        let width = label.intrinsicContentSize.width + 28
        let size = CGSize(width: max(width, 44), height: 34)
        setFrame(
            Coords.appKitRect(fromCG: CGRect(
                origin: CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height),
                size: size)),
            display: true)
        alphaValue = 1
        orderFrontRegardless()

        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, !Task.isCancelled else { return }
            self.fadeOutNow()
        }
    }

    // In an async context the trailing-closure call resolves to the async
    // runAnimationGroup overload — keep it in a synchronous method.
    private func fadeOutNow() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            self.animator().alphaValue = 0
        }
        buffer = ""
        bufferIsTyping = false
    }
}
