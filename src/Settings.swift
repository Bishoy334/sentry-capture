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
    @Published var playSound: Bool
    @Published var downscaleRetina: Bool
    @Published var showCursorInRecording: Bool
    @Published var recordSystemAudio: Bool
    @Published var recordMicrophone: Bool
    @Published var videoFPS: Int
    @Published var gifFPS: Int
    @Published var recordingCountdown: Int
    @Published var freezeSelectionScreen: Bool
    @Published var selfTimerSeconds: Int
    @Published var hotkeys: [HotkeyAction: Hotkey?]

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
        filenamePrefix = d.string(forKey: "filenamePrefix") ?? "Sentry Capture"
        imageFormat = ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png
        copyToClipboard = d.object(forKey: "copyToClipboard") as? Bool ?? true
        saveToDisk = d.object(forKey: "saveToDisk") as? Bool ?? true
        showQuickAccess = d.object(forKey: "showQuickAccess") as? Bool ?? true
        playSound = d.object(forKey: "playSound") as? Bool ?? true
        downscaleRetina = d.object(forKey: "downscaleRetina") as? Bool ?? false
        showCursorInRecording = d.object(forKey: "showCursorInRecording") as? Bool ?? true
        recordSystemAudio = d.object(forKey: "recordSystemAudio") as? Bool ?? true
        recordMicrophone = d.object(forKey: "recordMicrophone") as? Bool ?? false
        videoFPS = d.object(forKey: "videoFPS") as? Int ?? 60
        gifFPS = d.object(forKey: "gifFPS") as? Int ?? 12
        recordingCountdown = d.object(forKey: "recordingCountdown") as? Int ?? 3
        freezeSelectionScreen = d.object(forKey: "freezeSelectionScreen") as? Bool ?? true
        selfTimerSeconds = d.object(forKey: "selfTimerSeconds") as? Int ?? 5

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
        d.set(playSound, forKey: "playSound")
        d.set(downscaleRetina, forKey: "downscaleRetina")
        d.set(showCursorInRecording, forKey: "showCursorInRecording")
        d.set(recordSystemAudio, forKey: "recordSystemAudio")
        d.set(recordMicrophone, forKey: "recordMicrophone")
        d.set(videoFPS, forKey: "videoFPS")
        d.set(gifFPS, forKey: "gifFPS")
        d.set(recordingCountdown, forKey: "recordingCountdown")
        d.set(freezeSelectionScreen, forKey: "freezeSelectionScreen")
        d.set(selfTimerSeconds, forKey: "selfTimerSeconds")
        let encodable = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            d.set(data, forKey: "hotkeys")
        }
    }

    func hotkey(for action: HotkeyAction) -> Hotkey? {
        hotkeys[action] ?? nil
    }
}
