import AppKit
import Combine
import ServiceManagement

enum ImageFormat: String, CaseIterable, Codable {
    case png, jpg

    var fileExtension: String { rawValue }
    var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    static let changed = Notification.Name("SettingsChanged")

    private let d = UserDefaults.standard

    @Published var saveDirectoryPath: String
    @Published var filenamePrefix: String
    @Published var imageFormat: ImageFormat
    @Published var copyToClipboard: Bool
    @Published var saveToDisk: Bool
    @Published var showQuickAccess: Bool
    @Published var qaoCorner: String
    @Published var qaoAutoCloseSeconds: Int
    @Published var playSound: Bool
    @Published var downscaleRetina: Bool
    @Published var showCursorInRecording: Bool
    @Published var showClicksInRecording: Bool
    @Published var showKeystrokesInRecording: Bool
    @Published var showWebcamInRecording: Bool
    /// small | medium | large — bubble diameter in the recording.
    @Published var webcamBubbleSize: String
    @Published var showCursorHalo: Bool
    @Published var hideDesktopWhileRecording: Bool
    @Published var recordSystemAudio: Bool
    @Published var recordMicrophone: Bool
    @Published var videoFPS: Int
    @Published var gifFPS: Int
    @Published var recordingCountdown: Int
    @Published var freezeSelectionScreen: Bool
    /// Window captures get a transparent margin + composited drop shadow.
    @Published var windowCaptureShadow: Bool
    @Published var selfTimerSeconds: Int
    /// Days to keep captures; 0 = forever. Expired records move to the Bin.
    @Published var retentionDays: Int
    /// OCR recognition language; empty = automatic detection.
    @Published var ocrLanguage: String
    @Published var hotkeys: [HotkeyAction: Hotkey?]
    /// Own ⌘⇧3/4/5 by disabling the built-in macOS screenshot shortcuts.
    @Published var useMacScreenshotHotkeys: Bool

    var saveDirectory: URL {
        URL(fileURLWithPath: (saveDirectoryPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("launch-at-login toggle failed: \(error)")
            }
            objectWillChange.send()
        }
    }

    private var sinks: Set<AnyCancellable> = []

    private init() {
        // One-time v1 migration: adopt macOS-style screenshot shortcuts
        // (⌘⇧3/4/5), a bottom-right overlay, and dev-friendly timestamp
        // filenames on installs that predate them. Clearing "hotkeys" makes the
        // loader fall back to the new defaultHotkey values.
        if d.integer(forKey: "settingsVersion") < 1 {
            d.removeObject(forKey: "hotkeys")
            d.set("bottomRight", forKey: "qaoCorner")
            d.set("Sentry-Capture_{date}_{time}", forKey: "filenamePrefix")
            d.set(1, forKey: "settingsVersion")
        }

        // ~/Sentry/ is the ecosystem root — captures are records other Sentry
        // apps read (see SENTRY_SCHEMA.md). One-shot migration from the
        // round-1 Desktop default; a later deliberate choice of ~/Desktop
        // sticks because the flag only fires once.
        var storedPath = d.string(forKey: "saveDirectoryPath") ?? "~/Sentry/captures"
        if storedPath == "~/Desktop", !d.bool(forKey: "migratedToSentryRoot") {
            storedPath = "~/Sentry/captures"
        }
        d.set(true, forKey: "migratedToSentryRoot")
        saveDirectoryPath = storedPath
        filenamePrefix = d.string(forKey: "filenamePrefix") ?? "Sentry-Capture_{date}_{time}"
        imageFormat = ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png
        copyToClipboard = d.object(forKey: "copyToClipboard") as? Bool ?? true
        saveToDisk = d.object(forKey: "saveToDisk") as? Bool ?? true
        showQuickAccess = d.object(forKey: "showQuickAccess") as? Bool ?? true
        qaoCorner = d.string(forKey: "qaoCorner") ?? "bottomRight"
        qaoAutoCloseSeconds = d.object(forKey: "qaoAutoCloseSeconds") as? Int ?? 0
        playSound = d.object(forKey: "playSound") as? Bool ?? true
        downscaleRetina = d.object(forKey: "downscaleRetina") as? Bool ?? false
        showCursorInRecording = d.object(forKey: "showCursorInRecording") as? Bool ?? true
        showClicksInRecording = d.object(forKey: "showClicksInRecording") as? Bool ?? false
        showKeystrokesInRecording = d.object(forKey: "showKeystrokesInRecording") as? Bool ?? false
        showWebcamInRecording = d.object(forKey: "showWebcamInRecording") as? Bool ?? false
        webcamBubbleSize = d.string(forKey: "webcamBubbleSize") ?? "medium"
        showCursorHalo = d.object(forKey: "showCursorHalo") as? Bool ?? false
        hideDesktopWhileRecording = d.object(forKey: "hideDesktopWhileRecording") as? Bool ?? false
        recordSystemAudio = d.object(forKey: "recordSystemAudio") as? Bool ?? true
        recordMicrophone = d.object(forKey: "recordMicrophone") as? Bool ?? false
        videoFPS = d.object(forKey: "videoFPS") as? Int ?? 60
        gifFPS = d.object(forKey: "gifFPS") as? Int ?? 12
        recordingCountdown = d.object(forKey: "recordingCountdown") as? Int ?? 3
        freezeSelectionScreen = d.object(forKey: "freezeSelectionScreen") as? Bool ?? true
        windowCaptureShadow = d.object(forKey: "windowCaptureShadow") as? Bool ?? true
        selfTimerSeconds = d.object(forKey: "selfTimerSeconds") as? Int ?? 5
        retentionDays = d.object(forKey: "retentionDays") as? Int ?? 0
        ocrLanguage = d.string(forKey: "ocrLanguage") ?? ""
        useMacScreenshotHotkeys = d.object(forKey: "useMacScreenshotHotkeys") as? Bool ?? true

        var loaded: [HotkeyAction: Hotkey?] = [:]
        let stored = (try? JSONDecoder().decode(
            [String: Hotkey?].self,
            from: d.data(forKey: "hotkeys") ?? Data()
        )) ?? [:]
        for action in HotkeyAction.allCases {
            if let entry = stored[action.rawValue] {
                loaded[action] = entry // user-set, possibly explicitly nil (unbound)
            } else {
                loaded[action] = action.defaultHotkey
            }
        }
        hotkeys = loaded

        // Persist on any change, then broadcast so hotkeys re-register and
        // open windows pick up new values.
        objectWillChange
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.persist()
                NotificationCenter.default.post(name: Settings.changed, object: nil)
            }
            .store(in: &sinks)
    }

    private func persist() {
        d.set(saveDirectoryPath, forKey: "saveDirectoryPath")
        d.set(filenamePrefix, forKey: "filenamePrefix")
        d.set(imageFormat.rawValue, forKey: "imageFormat")
        d.set(copyToClipboard, forKey: "copyToClipboard")
        d.set(saveToDisk, forKey: "saveToDisk")
        d.set(showQuickAccess, forKey: "showQuickAccess")
        d.set(qaoCorner, forKey: "qaoCorner")
        d.set(qaoAutoCloseSeconds, forKey: "qaoAutoCloseSeconds")
        d.set(playSound, forKey: "playSound")
        d.set(downscaleRetina, forKey: "downscaleRetina")
        d.set(showCursorInRecording, forKey: "showCursorInRecording")
        d.set(showClicksInRecording, forKey: "showClicksInRecording")
        d.set(showKeystrokesInRecording, forKey: "showKeystrokesInRecording")
        d.set(showWebcamInRecording, forKey: "showWebcamInRecording")
        d.set(webcamBubbleSize, forKey: "webcamBubbleSize")
        d.set(showCursorHalo, forKey: "showCursorHalo")
        d.set(hideDesktopWhileRecording, forKey: "hideDesktopWhileRecording")
        d.set(recordSystemAudio, forKey: "recordSystemAudio")
        d.set(recordMicrophone, forKey: "recordMicrophone")
        d.set(videoFPS, forKey: "videoFPS")
        d.set(gifFPS, forKey: "gifFPS")
        d.set(recordingCountdown, forKey: "recordingCountdown")
        d.set(freezeSelectionScreen, forKey: "freezeSelectionScreen")
        d.set(windowCaptureShadow, forKey: "windowCaptureShadow")
        d.set(selfTimerSeconds, forKey: "selfTimerSeconds")
        d.set(retentionDays, forKey: "retentionDays")
        d.set(ocrLanguage, forKey: "ocrLanguage")
        d.set(useMacScreenshotHotkeys, forKey: "useMacScreenshotHotkeys")
        let encodable = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            d.set(data, forKey: "hotkeys")
        }
    }

    func hotkey(for action: HotkeyAction) -> Hotkey? {
        hotkeys[action] ?? nil
    }
}
