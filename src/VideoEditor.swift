import AVFoundation
import AVKit
import AppKit

/// Post-recording editor for MP4 captures: native QuickTime-style trimming,
/// resolution reduction and mute, previewed live. Save re-exports over the
/// record's media in place — one evolving record, same as annotator saves.
@MainActor
final class VideoEditorController: NSObject, NSWindowDelegate {
    static let shared = VideoEditorController()

    private var window: NSWindow?
    private var editorView: VideoEditorView?
    private var holdsActivation = false

    private override init() {
        super.init()
    }

    func open(recordID: String) {
        guard let manifest = SentryStore.shared.loadManifest(for: recordID),
              manifest.media.type == "video/mp4" else {
            Toast.show("Only MP4 recordings can be edited", symbol: "film")
            return
        }
        let mediaURL = SentryStore.shared.recordDirectory(for: recordID)
            .appendingPathComponent(manifest.media.path)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            Toast.show("Recording file is missing", symbol: "questionmark.folder")
            return
        }

        // One editor at a time — a second open replaces the first.
        window?.close()

        let editor = VideoEditorView(recordID: recordID, mediaURL: mediaURL)
        editor.onSaved = { [weak self] in self?.window?.close() }
        let w = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        w.title = "Edit Recording"
        w.contentView = editor
        w.isReleasedWhenClosed = false
        w.setContentSize(editor.preferredContentSize())
        w.contentMinSize = NSSize(width: 560, height: 380)
        w.center()
        w.delegate = self
        window = w
        editorView = editor

        if holdsActivation {
            NSApp.activate()
        } else {
            holdsActivation = true
            AppActivation.acquire()
        }
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        editorView?.teardown()
        editorView = nil
        window = nil
        if holdsActivation {
            holdsActivation = false
            AppActivation.release()
        }
    }
}

// MARK: - Editor view

@MainActor
private final class VideoEditorView: NSView {
    var onSaved: (() -> Void)?

    private let recordID: String
    private let mediaURL: URL
    private let asset: AVURLAsset
    private let player: AVPlayer
    private let playerView = AVPlayerView()

    private var trimButton: NSButton!
    private var sizePopup: NSPopUpButton!
    private var muteToggle: NSButton!
    private var saveButton: NSButton!
    private var spinner: NSProgressIndicator!

    private var naturalSize = CGSize(width: 1280, height: 720)
    private var exporting = false

    /// (title, export preset). Presets fit within the target — they never upscale.
    private static let sizeOptions: [(String, String)] = [
        ("Original size", AVAssetExportPresetHighestQuality),
        ("1080p", AVAssetExportPreset1920x1080),
        ("720p", AVAssetExportPreset1280x720),
        ("540p", AVAssetExportPreset960x540),
    ]

    init(recordID: String, mediaURL: URL) {
        self.recordID = recordID
        self.mediaURL = mediaURL
        asset = AVURLAsset(url: mediaURL)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        super.init(frame: .zero)
        build()
        Task { [weak self] in
            guard let track = try? await self?.asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize) else { return }
            self?.naturalSize = size
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func teardown() {
        player.pause()
        playerView.player = nil
    }

    func preferredContentSize() -> NSSize {
        // Sized before naturalSize loads — a sane default; the window resizes freely.
        NSSize(width: 960, height: 620)
    }

    private func build() {
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)

        trimButton = NSButton(title: "Trim", target: self, action: #selector(trimTapped))
        trimButton.bezelStyle = .rounded
        trimButton.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Trim")
        trimButton.imagePosition = .imageLeading

        sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (title, _) in Self.sizeOptions { sizePopup.addItem(withTitle: title) }

        muteToggle = NSButton(title: "Mute", target: self, action: #selector(muteToggled))
        muteToggle.setButtonType(.switch)

        saveButton = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.bezelColor = .controlAccentColor

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [trimButton, sizePopup, muteToggle, spacer, spinner, saveButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    // MARK: Controls

    @objc private func trimTapped() {
        guard playerView.canBeginTrimming else {
            Toast.show("This recording can't be trimmed", symbol: "scissors")
            return
        }
        trimButton.isEnabled = false
        playerView.beginTrimming { [weak self] _ in
            // Both outcomes land here; on OK the player item's playback end
            // times now carry the trimmed range — read at export time.
            Task { @MainActor in self?.trimButton.isEnabled = true }
        }
    }

    @objc private func muteToggled() {
        player.isMuted = muteToggle.state == .on
    }

    /// The player item's trim (set by the native trim UI); full range when untrimmed.
    private func selectedRange() async throws -> CMTimeRange {
        let duration = try await asset.load(.duration)
        guard let item = player.currentItem else {
            return CMTimeRange(start: .zero, duration: duration)
        }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : duration
        guard end > start else { return CMTimeRange(start: .zero, duration: duration) }
        return CMTimeRange(start: start, end: end)
    }

    // MARK: Export

    @objc private func saveTapped() {
        guard !exporting else { return }
        exporting = true
        player.pause()
        setBusy(true)
        let preset = Self.sizeOptions[sizePopup.indexOfSelectedItem].1
        let muted = muteToggle.state == .on

        Task { @MainActor in
            do {
                let range = try await selectedRange()
                let tempURL = try await export(range: range, preset: preset, muted: muted)
                if SentryStore.shared.updateVideoMedia(
                    recordID: recordID, tempURL: tempURL,
                    durationSeconds: range.duration.seconds) != nil {
                    Toast.show("Recording saved", symbol: "film")
                    onSaved?()
                } else {
                    try? FileManager.default.removeItem(at: tempURL)
                    Toast.show("Could not save recording", symbol: "exclamationmark.triangle")
                }
            } catch {
                NSLog("video export failed: \(error)")
                Toast.show("Export failed: \(error.localizedDescription)",
                           symbol: "exclamationmark.triangle")
            }
            exporting = false
            setBusy(false)
        }
    }

    private func setBusy(_ busy: Bool) {
        trimButton.isEnabled = !busy
        sizePopup.isEnabled = !busy
        muteToggle.isEnabled = !busy
        saveButton.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// Re-encodes the selected range into a temp MP4. A composition (rather
    /// than the raw asset) is what lets mute drop the audio tracks entirely.
    private func export(range: CMTimeRange, preset: String, muted: Bool) async throws -> URL {
        let composition = AVMutableComposition()
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let video = composition.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoEditor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No video track found"])
        }
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        if !muted {
            // System audio and microphone record as separate tracks — keep all.
            for sourceAudio in try await asset.loadTracks(withMediaType: .audio) {
                let audio = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try audio?.insertTimeRange(range, of: sourceAudio, at: .zero)
            }
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw NSError(domain: "VideoEditor", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Export preset unavailable"])
        }
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sentry-edit-\(UUID().uuidString).mp4")
        try await session.export(to: tempURL, as: .mp4)
        return tempURL
    }
}
