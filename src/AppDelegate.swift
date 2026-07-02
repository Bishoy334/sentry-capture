import AppKit
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var recordingTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        menu.delegate = self
        statusItem.menu = menu

        registerHotkeys()
        NotificationCenter.default.addObserver(
            forName: Settings.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotkeys() }
        }

        OutputRouter.shared.onRecentsChanged = { /* menu rebuilds on open */ }
        RecordingController.shared.onStateChange = { [weak self] in
            self?.updateStatusIcon()
        }

        if !CaptureEngine.shared.hasPermission {
            CaptureEngine.shared.requestPermission()
        }
    }

    private func registerHotkeys() {
        HotkeyManager.shared.registerAll { [weak self] action in
            self?.dispatch(action)
        }
    }

    private func updateStatusIcon() {
        let recording = RecordingController.shared.isRecording
        let name = recording ? "stop.circle.fill" : "camera.viewfinder"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Sentry Capture")
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
        statusItem.button?.imagePosition = recording ? .imageLeading : .imageOnly

        // While recording the whole status item is the stop button — no menu
        // between the user and stopping. The menu comes back when idle.
        if recording {
            statusItem.menu = nil
            statusItem.button?.target = self
            statusItem.button?.action = #selector(stopRecording)
            recordingTimer?.invalidate()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let s = Int(RecordingController.shared.recordedDuration)
                    self.statusItem.button?.title = String(format: " %d:%02d", s / 60, s % 60)
                }
            }
            statusItem.button?.title = " 0:00"
        } else {
            recordingTimer?.invalidate()
            recordingTimer = nil
            statusItem.button?.title = ""
            statusItem.button?.action = nil
            statusItem.menu = menu
        }
    }

    // MARK: Dispatch

    func dispatch(_ action: HotkeyAction) {
        // Recording hotkey doubles as stop while a recording is live.
        if RecordingController.shared.isRecording {
            if action == .recordVideo || action == .recordGIF {
                RecordingController.shared.stop()
            }
            return
        }
        guard !SelectionController.shared.isActive else { return }
        guard CaptureEngine.shared.hasPermission else {
            CaptureEngine.shared.requestPermission()
            return
        }

        switch action {
        case .captureArea:
            beginStillSelection(.still)
        case .captureWindow:
            beginStillSelection(.window)
        case .captureFullscreen:
            Task { @MainActor in
                await self.runCapture { try await CaptureEngine.shared.captureActiveDisplay() }
            }
        case .scrollingCapture:
            SelectionController.shared.begin(mode: .scrolling) { selection in
                guard let selection else { return }
                ScrollingCaptureController.shared.begin(selection: selection)
            }
        case .recordVideo:
            SelectionController.shared.begin(mode: .record) { selection in
                guard let selection else { return }
                RecordingController.shared.start(selection: selection, asGIF: false)
            }
        case .recordGIF:
            SelectionController.shared.begin(mode: .record) { selection in
                guard let selection else { return }
                RecordingController.shared.start(selection: selection, asGIF: true)
            }
        case .copyText:
            SelectionController.shared.begin(mode: .ocr) { selection in
                guard let selection else { return }
                Task { @MainActor in
                    if let still = await self.capture(selection) {
                        OutputRouter.shared.copyText(from: still)
                    }
                }
            }
        case .pinArea:
            SelectionController.shared.begin(mode: .pin) { selection in
                guard let selection else { return }
                Task { @MainActor in
                    if let still = await self.capture(selection) {
                        PinController.shared.pin(still)
                    }
                }
            }
        }
    }

    private func beginStillSelection(_ mode: SelectionController.Mode) {
        SelectionController.shared.begin(mode: mode) { selection in
            guard let selection else { return }
            Task { @MainActor in
                if let still = await self.capture(selection) {
                    OutputRouter.shared.deliver(still)
                }
            }
        }
    }

    /// Selection → pixels, routing window picks to the window capturer.
    private func capture(_ selection: SelectionController.Selection) async -> StillCapture? {
        do {
            if let window = selection.window {
                return try await CaptureEngine.shared.captureWindow(window)
            }
            return try await CaptureEngine.shared.captureRect(selection.rect)
        } catch {
            Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
            return nil
        }
    }

    private func runCapture(_ work: @escaping () async throws -> StillCapture) async {
        do {
            let still = try await work()
            OutputRouter.shared.deliver(still)
        } catch {
            Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if RecordingController.shared.isRecording {
            menu.addItem(item("Stop Recording", #selector(stopRecording), key: ""))
            menu.addItem(.separator())
        }

        for action in [HotkeyAction.captureArea, .captureWindow, .captureFullscreen, .scrollingCapture] {
            menu.addItem(actionItem(action))
        }
        menu.addItem(.separator())
        for action in [HotkeyAction.recordVideo, .recordGIF] {
            menu.addItem(actionItem(action))
        }
        menu.addItem(.separator())
        for action in [HotkeyAction.copyText, .pinArea] {
            menu.addItem(actionItem(action))
        }
        menu.addItem(.separator())

        let recents = OutputRouter.shared.recents
        let recentsItem = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        let recentsMenu = NSMenu()
        if recents.isEmpty {
            let empty = NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentsMenu.addItem(empty)
        } else {
            for url in recents {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                recentsMenu.addItem(item)
            }
        }
        recentsItem.submenu = recentsMenu
        menu.addItem(recentsItem)
        menu.addItem(item("Open Captures Folder", #selector(openCapturesFolder), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showPreferences), key: ","))
        menu.addItem(item("Quit Sentry Capture", #selector(quit), key: "q"))
    }

    private func actionItem(_ action: HotkeyAction) -> NSMenuItem {
        let item = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        if let hotkey = Settings.shared.hotkey(for: action) {
            // Shown as plain suffix — Carbon owns the actual binding.
            item.title = action.title
            item.toolTip = hotkey.display
        }
        return item
    }

    private func item(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = HotkeyAction(rawValue: raw) else { return }
        // Give the menu time to close so it isn't in the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.dispatch(action)
        }
    }

    @objc private func stopRecording() {
        RecordingController.shared.stop()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openCapturesFolder() {
        NSWorkspace.shared.open(Settings.shared.saveDirectory)
    }

    @objc private func showPreferences() {
        PreferencesController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
