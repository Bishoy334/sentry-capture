import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// MARK: - Controller

/// The single settings window. The window and its SwiftUI content are
/// discarded on close; the controller singleton survives and recreates them
/// on the next show().
@MainActor
final class PreferencesController: NSObject, NSWindowDelegate {
    static let shared = PreferencesController()

    private var window: NSWindow?
    private var holdsActivation = false

    private override init() {
        super.init()
    }

    func show() {
        if window == nil {
            window = makeWindow()
            window?.center()
        }
        // Keep acquire/release balanced when show() lands on an open window.
        if holdsActivation {
            NSApp.activate()
        } else {
            holdsActivation = true
            AppActivation.acquire()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        if holdsActivation {
            holdsActivation = false
            AppActivation.release()
        }
    }

    private func makeWindow() -> NSWindow {
        let tabs = PreferencesTabViewController()
        tabs.tabStyle = .toolbar

        let panes: [(label: String, symbol: String, controller: NSViewController)] = [
            ("General", "gearshape", NSHostingController(rootView: PrefsGeneralPane()
                .frame(width: prefsPaneSize.width, height: prefsPaneSize.height))),
            ("Shortcuts", "command", NSHostingController(rootView: PrefsShortcutsPane()
                .frame(width: prefsPaneSize.width, height: prefsPaneSize.height))),
            ("Screenshots", "photo", NSHostingController(rootView: PrefsScreenshotsPane()
                .frame(width: prefsPaneSize.width, height: prefsPaneSize.height))),
            ("Recording", "record.circle", NSHostingController(rootView: PrefsRecordingPane()
                .frame(width: prefsPaneSize.width, height: prefsPaneSize.height))),
        ]
        for pane in panes {
            let item = NSTabViewItem(viewController: pane.controller)
            item.label = pane.label
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.label)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sentry Capture Settings"
        window.toolbarStyle = .preference
        window.contentViewController = tabs
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

private let prefsPaneSize = NSSize(width: 540, height: 400)

/// Some AppKit versions propagate the selected tab's label into the window
/// title; pin ours back after every selection change.
private final class PreferencesTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = "Sentry Capture Settings"
    }
}

// MARK: - General

private struct PrefsGeneralPane: View {
    @ObservedObject private var settings = Settings.shared
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section("After capture") {
                Toggle("Copy to clipboard", isOn: $settings.copyToClipboard)
                Toggle("Save to disk", isOn: $settings.saveToDisk)
                Toggle("Show quick access overlay", isOn: $settings.showQuickAccess)
                Toggle("Play capture sound", isOn: $settings.playSound)
            }
            Section("System") {
                Toggle("Launch at login", isOn: launchAtLogin)
                if loginStatus == .requiresApproval {
                    LabeledContent("Waiting for approval in System Settings") {
                        Button("Open Login Items…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // The user can flip the login item in System Settings — never cache.
            loginStatus = SMAppService.mainApp.status
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: {
                settings.launchAtLogin = $0
                loginStatus = SMAppService.mainApp.status
            }
        )
    }
}

// MARK: - Shortcuts

private struct PrefsShortcutsPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    HStack(spacing: 8) {
                        Text(action.title)
                        Spacer()
                        PrefsShortcutRecorderField(
                            action: action,
                            display: settings.hotkey(for: action)?.display
                        )
                        .frame(width: 150, height: 22)
                        Button {
                            // Explicitly unbound — distinct from "use the default".
                            settings.hotkeys.updateValue(nil, forKey: action)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(settings.hotkey(for: action) == nil)
                        .help("Remove shortcut")
                    }
                }
            } footer: {
                Text("Shortcuts need ⌘ or ⌃ — macOS does not deliver Option-only combinations.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Screenshots

private struct PrefsScreenshotsPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $settings.imageFormat) {
                    Text("PNG").tag(ImageFormat.png)
                    Text("JPG").tag(ImageFormat.jpg)
                }
                TextField("Filename prefix", text: $settings.filenamePrefix)
                Toggle("Scale Retina screenshots down to 1x", isOn: $settings.downscaleRetina)
                Toggle("Freeze screen while selecting", isOn: $settings.freezeSelectionScreen)
                Picker("Self-timer delay", selection: $settings.selfTimerSeconds) {
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            }
            Section {
                LabeledContent("Save location") {
                    HStack(spacing: 8) {
                        Text((settings.saveDirectoryPath as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseSaveLocation() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        panel.prompt = "Choose"
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            settings.saveDirectoryPath = (url.path as NSString).abbreviatingWithTildeInPath
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }
}

// MARK: - Recording

private struct PrefsRecordingPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker("Video frame rate", selection: $settings.videoFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("GIF frame rate", selection: $settings.gifFPS) {
                    Text("10 fps").tag(10)
                    Text("12 fps").tag(12)
                    Text("15 fps").tag(15)
                }
                Picker("Countdown", selection: $settings.recordingCountdown) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            }
            Section {
                Toggle("Show cursor", isOn: $settings.showCursorInRecording)
                Toggle("Record system audio", isOn: $settings.recordSystemAudio)
                Toggle("Record microphone", isOn: $settings.recordMicrophone)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcut recorder

private struct PrefsShortcutRecorderField: NSViewRepresentable {
    let action: HotkeyAction
    /// Stored only so SwiftUI re-runs updateNSView when the binding changes
    /// underneath us (e.g. the clear button).
    let display: String?

    func makeNSView(context: Context) -> PrefsShortcutRecorderView {
        PrefsShortcutRecorderView(action: action)
    }

    func updateNSView(_ view: PrefsShortcutRecorderView, context: Context) {
        view.refreshIdleDisplay()
    }

    static func dismantleNSView(_ view: PrefsShortcutRecorderView, coordinator: ()) {
        view.cancelRecording()
    }
}

private let prefsRecognisedModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

/// Button-like field that records a global shortcut via a local event
/// monitor. While armed our own Carbon hotkeys must be unregistered — a
/// registered global hotkey swallows the keypress system-wide before any
/// local monitor sees it.
private final class PrefsShortcutRecorderView: NSView {
    private enum RecorderState {
        case idle
        case armed
        case warning(String)
    }

    /// Only one recorder captures at a time.
    private static weak var armedField: PrefsShortcutRecorderView?

    private let action: HotkeyAction
    private var state: RecorderState = .idle {
        didSet { needsDisplay = true }
    }
    private var liveModifiers: NSEvent.ModifierFlags = []
    private var monitor: Any?
    private var settingsObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var warningReset: Task<Void, Never>?

    init(action: HotkeyAction) {
        self.action = action
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(action.title) shortcut")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 150, height: 22)
    }

    private var isArmed: Bool {
        if case .idle = state { return false }
        return true
    }

    func refreshIdleDisplay() {
        if !isArmed { needsDisplay = true }
    }

    // MARK: Arm / disarm

    override func mouseDown(with event: NSEvent) {
        if isArmed {
            cancelRecording()
        } else {
            arm()
        }
    }

    private func arm() {
        Self.armedField?.cancelRecording()
        Self.armedField = self

        HotkeyManager.shared.unregisterAll()
        liveModifiers = NSEvent.modifierFlags.intersection(prefsRecognisedModifiers)
        state = .armed

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let swallow = MainActor.assumeIsolated { self.consume(event) }
            return swallow ? nil : event
        }
        // Any Settings change while armed (e.g. a clear button) makes the
        // AppDelegate re-register every hotkey — undo that until we disarm.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: Settings.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isArmed else { return }
                HotkeyManager.shared.unregisterAll()
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
    }

    func cancelRecording() {
        guard isArmed else { return }
        disarm(reregister: true)
    }

    private func disarm(reregister: Bool) {
        warningReset?.cancel()
        warningReset = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if Self.armedField === self { Self.armedField = nil }
        state = .idle
        if reregister {
            // Nothing in Settings changed, so its debounced broadcast never
            // fires — post directly so the AppDelegate re-registers hotkeys.
            NotificationCenter.default.post(name: Settings.changed, object: nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelRecording() }
    }

    // MARK: Capture

    /// Returns true when the event was consumed and must not propagate.
    private func consume(_ event: NSEvent) -> Bool {
        guard isArmed else { return false }
        let mods = event.modifierFlags.intersection(prefsRecognisedModifiers)

        if event.type == .flagsChanged {
            liveModifiers = mods
            needsDisplay = true
            return false
        }
        guard !event.isARepeat else { return true }
        if event.keyCode == UInt16(kVK_Escape), mods.isEmpty {
            cancelRecording()
            return true
        }
        // Bare keys are unusable as global shortcuts, and Option-only /
        // Option-Shift-only combos never fire on macOS 15+ (FB15168205).
        guard mods.contains(.command) || mods.contains(.control) else {
            showWarning("Needs ⌘ or ⌃")
            return true
        }
        Settings.shared.hotkeys[action] = Hotkey(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: mods.carbonModifiers
        )
        // Re-registration follows from the Settings.changed broadcast.
        disarm(reregister: false)
        return true
    }

    private func showWarning(_ message: String) {
        state = .warning(message)
        warningReset?.cancel()
        warningReset = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard let self, !Task.isCancelled else { return }
            if case .warning = self.state { self.state = .armed }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        let accent = NSColor.controlAccentColor

        let fill: NSColor
        let border: NSColor
        switch state {
        case .idle:
            fill = .quaternarySystemFill
            border = .separatorColor
        case .armed:
            fill = accent.withAlphaComponent(0.1)
            border = accent
        case .warning:
            fill = NSColor.systemOrange.withAlphaComponent(0.1)
            border = .systemOrange
        }
        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()

        let text: String
        let colour: NSColor
        switch state {
        case .idle:
            if let display = Settings.shared.hotkey(for: action)?.display {
                text = display
                colour = .labelColor
            } else {
                text = "Record Shortcut"
                colour = .secondaryLabelColor
            }
        case .armed:
            if liveModifiers.isEmpty {
                text = "Press shortcut…"
                colour = .secondaryLabelColor
            } else {
                text = modifierGlyphs(liveModifiers)
                colour = .labelColor
            }
        case .warning(let message):
            text = message
            colour = .systemOrange
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: colour,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    private func modifierGlyphs(_ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
