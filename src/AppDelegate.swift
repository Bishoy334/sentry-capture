import AppKit
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var recordingTimer: Timer?

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            SentryRegistry.handle(url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SentryRegistry.advertiseSelf()
        installMainMenu()
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

    /// An accessory app has no menu bar by default, but Cmd-key editing
    /// shortcuts in text fields are menu-driven — without an Edit menu,
    /// Cmd-V/C/X/A are dead in Settings and text annotations, and Cmd-W
    /// can't close windows. Window-level performKeyEquivalent overrides
    /// (annotator) still win because windows get the event before the menu.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "Quit Sentry Capture",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(
            title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
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
        // Recording hotkey doubles as stop. Gate on isBusy, not isRecording:
        // during the countdown / stream spin-up window isRecording is still
        // false, and starting a second flow there records our own selection
        // overlay into the live video.
        if RecordingController.shared.isBusy {
            if action == .recordVideo || action == .recordGIF {
                RecordingController.shared.stop()
            }
            return
        }
        // A live scrolling session owns the screen: another overlay would be
        // stitched into the document (and auto-scroll would scroll the
        // overlay, not the page).
        guard !ScrollingCaptureController.shared.isActive else { return }
        guard !SelectionController.shared.isActive else { return }
        guard CaptureEngine.shared.hasPermission else {
            CaptureEngine.shared.requestPermission()
            return
        }

        switch action {
        case .allInOne:
            SelectionController.shared.begin(mode: .allInOne) { selection in
                guard let selection, let chosen = selection.chosenAction else { return }
                switch chosen {
                case .recordVideo:
                    RecordingController.shared.start(selection: selection, asGIF: false)
                case .recordGIF:
                    RecordingController.shared.start(selection: selection, asGIF: true)
                case .scrollingCapture:
                    ScrollingCaptureController.shared.begin(selection: selection)
                case .copyText:
                    Task { @MainActor in
                        if let still = await self.capture(selection) {
                            OutputRouter.shared.copyText(from: still)
                        }
                    }
                case .pinArea:
                    Task { @MainActor in
                        if let still = await self.capture(selection) {
                            PinController.shared.pin(still)
                        }
                    }
                default:
                    Task { @MainActor in
                        if let still = await self.capture(selection) {
                            OutputRouter.shared.deliver(still)
                        }
                    }
                }
            }
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
        case .timedCapture:
            SelectionController.shared.begin(mode: .still) { selection in
                guard var selection else { return }
                // The countdown exists to stage the screen (open a menu, hover
                // a state) — so the eventual capture must be LIVE, not the
                // frozen frame the selection was made on.
                selection.frozen = nil
                Task { @MainActor in
                    let seconds = max(1, Settings.shared.selfTimerSeconds)
                    for remaining in stride(from: seconds, through: 1, by: -1) {
                        Toast.show("Capturing in \(remaining)…", symbol: "timer", duration: 0.9)
                        try? await Task.sleep(for: .seconds(1))
                    }
                    if let still = await self.capture(selection) {
                        OutputRouter.shared.deliver(still)
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
    /// Origin metadata rides along for the record manifest.
    private func capture(_ selection: SelectionController.Selection) async -> StillCapture? {
        do {
            var still: StillCapture
            if let window = selection.window {
                still = try await CaptureEngine.shared.captureWindow(window)
                still.origin = CaptureOrigin(
                    appBundleID: window.owningApplication?.bundleIdentifier,
                    appName: window.owningApplication?.applicationName,
                    windowTitle: window.title,
                    displayID: selection.display.displayID)
            } else if let frozen = selection.frozen {
                // The overlay froze the screen — crop the frozen frame so the
                // user gets exactly the pixels they selected (menus, hover
                // states), not a re-shoot after the overlay closed.
                let origin = CaptureOrigin.frontmost(displayID: selection.display.displayID)
                let scale = frozen.scale
                let px = CGRect(
                    x: (selection.rect.minX - selection.display.frame.minX) * scale,
                    y: (selection.rect.minY - selection.display.frame.minY) * scale,
                    width: selection.rect.width * scale,
                    height: selection.rect.height * scale
                ).integral.intersection(
                    CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height))
                guard let cropped = frozen.image.cropping(to: px) else {
                    throw CaptureError.captureFailed("frozen crop out of bounds")
                }
                still = StillCapture(
                    image: cropped, scale: scale, source: .area,
                    screenRect: selection.rect, origin: origin)
            } else {
                let origin = CaptureOrigin.frontmost(displayID: selection.display.displayID)
                still = try await CaptureEngine.shared.captureRect(selection.rect)
                still.origin = origin
            }
            return still
        } catch {
            Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
            return nil
        }
    }

    private func runCapture(_ work: @escaping () async throws -> StillCapture) async {
        do {
            let origin = CaptureOrigin.frontmost()
            var still = try await work()
            if still.origin == nil { still.origin = origin }
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

        for action in [HotkeyAction.allInOne, .captureArea, .captureWindow, .captureFullscreen, .timedCapture, .scrollingCapture] {
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
        menu.addItem(item("Capture History…", #selector(showHistory), key: ""))
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

    @objc private func showHistory() {
        HistoryController.shared.show()
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
