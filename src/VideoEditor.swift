@preconcurrency import AVFoundation
import AVKit
import AppKit
import UniformTypeIdentifiers

/// Post-recording editor for MP4 captures: filmstrip timeline with in-place
/// trim handles, playback speed, volume, resolution reduction and GIF export,
/// previewed live. Save re-exports over the record's media in place — one
/// evolving record, same as annotator saves. Save as Copy leaves it alone.
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
        w.setContentSize(NSSize(width: 960, height: 660))
        w.contentMinSize = NSSize(width: 640, height: 440)
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
    private let timeline = VideoTimelineView()

    private let infoLabel = NSTextField(labelWithString: "")
    private var speedPopup: NSPopUpButton!
    private var sizePopup: NSPopUpButton!
    private var volumeSlider: NSSlider!
    private var gifButton: NSButton!
    private var copyButton: NSButton!
    private var saveButton: NSButton!
    private var spinner: NSProgressIndicator!

    private var durationSeconds: Double = 0
    private var timeObserver: Any?
    private var estimateTask: Task<Void, Never>?
    private var exporting = false

    /// (title, export preset). Presets fit within the target — they never upscale.
    private static let sizeOptions: [(String, String)] = [
        ("Original size", AVAssetExportPresetHighestQuality),
        ("1080p", AVAssetExportPreset1920x1080),
        ("720p", AVAssetExportPreset1280x720),
        ("540p", AVAssetExportPreset960x540),
    ]
    private static let speedOptions: [(String, Double)] = [
        ("0.5×", 0.5), ("1×", 1), ("1.5×", 1.5), ("2×", 2),
    ]

    init(recordID: String, mediaURL: URL) {
        self.recordID = recordID
        self.mediaURL = mediaURL
        asset = AVURLAsset(url: mediaURL)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        super.init(frame: .zero)
        build()
        loadAsset()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func teardown() {
        estimateTask?.cancel()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
        playerView.player = nil
    }

    // MARK: Build

    private func build() {
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)

        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.onTrimChanged = { [weak self] start, end, movedStart in
            self?.trimChanged(start: start, end: end, movedStart: movedStart)
        }
        timeline.onScrub = { [weak self] fraction in
            self?.seek(toFraction: fraction)
        }
        addSubview(timeline)

        infoLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail

        speedPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (title, _) in Self.speedOptions { speedPopup.addItem(withTitle: title) }
        speedPopup.selectItem(at: 1)
        speedPopup.target = self
        speedPopup.action = #selector(speedChanged)
        speedPopup.toolTip = "Playback and export speed"

        sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (title, _) in Self.sizeOptions { sizePopup.addItem(withTitle: title) }
        sizePopup.target = self
        sizePopup.action = #selector(refreshInfo)
        sizePopup.toolTip = "Export resolution"

        let speaker = NSImageView(image: NSImage(
            systemSymbolName: "speaker.wave.2", accessibilityDescription: "Volume") ?? NSImage())
        speaker.contentTintColor = .secondaryLabelColor
        volumeSlider = NSSlider(
            value: 1, minValue: 0, maxValue: 1,
            target: self, action: #selector(volumeChanged))
        volumeSlider.controlSize = .small
        volumeSlider.toolTip = "Volume (0 removes the audio track)"
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 70).isActive = true

        gifButton = NSButton(title: "GIF…", target: self, action: #selector(gifTapped))
        gifButton.bezelStyle = .rounded
        gifButton.toolTip = "Export the trimmed clip as a GIF"

        copyButton = NSButton(title: "Save as Copy…", target: self, action: #selector(saveCopyTapped))
        copyButton.bezelStyle = .rounded
        copyButton.toolTip = "Export to a new file, leaving this recording untouched"

        saveButton = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.bezelColor = .controlAccentColor
        saveButton.toolTip = "Replace this recording with the edit"

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [
            infoLabel, spacer, speedPopup, sizePopup, speaker, volumeSlider,
            spinner, gifButton, copyButton, saveButton,
        ])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.setCustomSpacing(2, after: speaker)
        bar.setCustomSpacing(16, after: volumeSlider)
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: timeline.topAnchor),
            timeline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            timeline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            timeline.bottomAnchor.constraint(equalTo: bar.topAnchor),
            timeline.heightAnchor.constraint(equalToConstant: 64),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func loadAsset() {
        Task { @MainActor in
            durationSeconds = (try? await asset.load(.duration))?.seconds ?? 0
            if !durationSeconds.isFinite { durationSeconds = 0 }
            // Handles can't cross closer than half a second of footage.
            if durationSeconds > 0 {
                timeline.minGap = min(0.5 / durationSeconds, 0.5)
            }
            refreshInfo()
            await generateThumbnails()
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.durationSeconds > 0 else { return }
                self.timeline.playheadFraction = CGFloat(time.seconds / self.durationSeconds)
            }
        }
    }

    private func generateThumbnails() async {
        guard durationSeconds > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 220, height: 120)
        let count = 12
        let times = (0..<count).map {
            CMTime(seconds: durationSeconds * (Double($0) + 0.5) / Double(count),
                   preferredTimescale: 600)
        }
        var thumbs: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                thumbs.append(image)
                timeline.thumbnails = thumbs
            }
        }
    }

    // MARK: Trim / scrub / preview state

    private var trimRange: CMTimeRange {
        let start = durationSeconds * Double(timeline.startFraction)
        let end = durationSeconds * Double(timeline.endFraction)
        return CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600))
    }

    private var speed: Double { Self.speedOptions[speedPopup.indexOfSelectedItem].1 }

    private func trimChanged(start: CGFloat, end: CGFloat, movedStart: Bool) {
        // The preview respects the trim: playback pins inside the range, and
        // the dragged handle scrubs so the cut point is visible frame-by-frame.
        player.pause()
        player.currentItem?.reversePlaybackEndTime = trimRange.start
        player.currentItem?.forwardPlaybackEndTime = trimRange.end
        seek(toFraction: movedStart ? start : end)
        refreshInfo()
    }

    private func seek(toFraction fraction: CGFloat) {
        guard durationSeconds > 0 else { return }
        let time = CMTime(
            seconds: durationSeconds * Double(fraction), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        timeline.playheadFraction = fraction
    }

    @objc private func speedChanged() {
        player.defaultRate = Float(speed)
        if player.rate > 0 { player.rate = Float(speed) }
        refreshInfo()
    }

    @objc private func volumeChanged() {
        player.volume = volumeSlider.floatValue
    }

    // MARK: Info readout

    private static func timeString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func refreshInfo() {
        let trimmed = trimRange.duration.seconds / speed
        var text = Self.timeString(trimmed)
        if trimRange.duration.seconds < durationSeconds - 0.05 || speed != 1 {
            text += " of \(Self.timeString(durationSeconds))"
        }
        infoLabel.stringValue = text

        // The byte estimate needs a full session — debounce and fill in behind.
        estimateTask?.cancel()
        let range = trimRange
        let preset = Self.sizeOptions[sizePopup.indexOfSelectedItem].1
        let muted = volumeSlider.doubleValue == 0
        let speed = speed
        estimateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            guard let (composition, audioMix) = try? await self.makeComposition(
                range: range, speed: speed, muted: muted),
                  let session = AVAssetExportSession(asset: composition, presetName: preset)
            else { return }
            session.audioMix = audioMix
            session.outputFileType = .mp4
            guard let bytes = try? await session.estimatedOutputFileLengthInBytes,
                  bytes > 0, !Task.isCancelled else { return }
            let mb = Double(bytes) / 1_048_576
            self.infoLabel.stringValue = text + String(format: " · ~%.1f MB", mb)
        }
    }

    // MARK: Composition + export

    /// The single source of export truth: trim, speed and volume all land in
    /// the composition/mix so Save, Save as Copy and GIF stay in agreement.
    private func makeComposition(
        range: CMTimeRange, speed: Double, muted: Bool
    ) async throws -> (AVMutableComposition, AVAudioMix?) {
        let composition = AVMutableComposition()
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let video = composition.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoEditor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No video track found"])
        }
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)

        var mix: AVMutableAudioMix?
        if !muted {
            var params: [AVMutableAudioMixInputParameters] = []
            // System audio and microphone record as separate tracks — keep all.
            for sourceAudio in try await asset.loadTracks(withMediaType: .audio) {
                guard let audio = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                try audio.insertTimeRange(range, of: sourceAudio, at: .zero)
                if volumeSlider.doubleValue < 1 {
                    let p = AVMutableAudioMixInputParameters(track: audio)
                    p.setVolume(volumeSlider.floatValue, at: .zero)
                    params.append(p)
                }
            }
            if !params.isEmpty {
                let m = AVMutableAudioMix()
                m.inputParameters = params
                mix = m
            }
        }
        if speed != 1 {
            let full = CMTimeRange(start: .zero, duration: composition.duration)
            let scaled = CMTime(
                seconds: composition.duration.seconds / speed, preferredTimescale: 600)
            composition.scaleTimeRange(full, toDuration: scaled)
        }
        return (composition, mix)
    }

    private func export(preset: String) async throws -> URL {
        let (composition, mix) = try await makeComposition(
            range: trimRange, speed: speed, muted: volumeSlider.doubleValue == 0)
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw NSError(domain: "VideoEditor", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Export preset unavailable"])
        }
        session.audioMix = mix
        // Sped-up audio keeps its pitch instead of chipmunking.
        session.audioTimePitchAlgorithm = .spectral
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sentry-edit-\(UUID().uuidString).mp4")
        try await session.export(to: tempURL, as: .mp4)
        return tempURL
    }

    private func runExport(_ work: @escaping () async throws -> Void) {
        guard !exporting else { return }
        exporting = true
        player.pause()
        setBusy(true)
        Task { @MainActor in
            do {
                try await work()
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
        for control in [speedPopup, sizePopup, volumeSlider, gifButton, copyButton, saveButton] {
            (control as? NSControl)?.isEnabled = !busy
        }
        timeline.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: Actions

    @objc private func saveTapped() {
        let preset = Self.sizeOptions[sizePopup.indexOfSelectedItem].1
        let duration = trimRange.duration.seconds / speed
        runExport { [weak self] in
            guard let self else { return }
            let tempURL = try await self.export(preset: preset)
            if SentryStore.shared.updateVideoMedia(
                recordID: self.recordID, tempURL: tempURL, durationSeconds: duration) != nil {
                Toast.show("Recording saved", symbol: "film")
                self.onSaved?()
            } else {
                try? FileManager.default.removeItem(at: tempURL)
                Toast.show("Could not save recording", symbol: "exclamationmark.triangle")
            }
        }
    }

    @objc private func saveCopyTapped() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = OutputRouter.shared.nextFileName(ext: "mp4")
        panel.directoryURL = Settings.shared.saveDirectory
        guard let window = self.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            let preset = Self.sizeOptions[self.sizePopup.indexOfSelectedItem].1
            self.runExport { [weak self] in
                guard let self else { return }
                let tempURL = try await self.export(preset: preset)
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
                Toast.show("Copy saved", symbol: "square.and.arrow.down")
            }
        }
    }

    @objc private func gifTapped() {
        guard trimRange.duration.seconds / speed <= 120 else {
            Toast.show("Trim to two minutes or less for a GIF", symbol: "photo.stack")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = OutputRouter.shared.nextFileName(ext: "gif")
        panel.directoryURL = Settings.shared.saveDirectory
        guard let window = self.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.runExport { [weak self] in
                guard let self else { return }
                // Encode a 720p intermediate — GIF quantisation gains nothing
                // from a full-res source and the frames are held in memory.
                let tempURL = try await self.export(preset: AVAssetExportPreset1280x720)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                let gif = try await GIFExporter.export(
                    from: tempURL, fps: Settings.shared.gifFPS, maxWidth: 1000)
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: gif)
                Toast.show("GIF saved", symbol: "photo.stack")
            }
        }
    }
}

// MARK: - Timeline

/// Filmstrip with draggable trim brackets and a playhead. All positions are
/// fractions of the full asset duration — the editor owns the time maths.
@MainActor
private final class VideoTimelineView: NSView {
    var thumbnails: [CGImage] = [] {
        didSet { needsDisplay = true }
    }
    private(set) var startFraction: CGFloat = 0
    private(set) var endFraction: CGFloat = 1
    var playheadFraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    /// Smallest allowed start→end gap, set from the asset duration.
    var minGap: CGFloat = 0.02
    var isEnabled = true

    /// (start, end, movedStart) — movedStart tells the editor which cut point
    /// to scrub to.
    var onTrimChanged: ((CGFloat, CGFloat, Bool) -> Void)?
    var onScrub: ((CGFloat) -> Void)?

    private enum Drag { case start, end, scrub }
    private var drag: Drag?

    private static let handleWidth: CGFloat = 8
    private var stripRect: NSRect {
        bounds.insetBy(dx: Self.handleWidth, dy: 8)
    }

    override var isFlipped: Bool { true }

    private func x(for fraction: CGFloat) -> CGFloat {
        stripRect.minX + stripRect.width * fraction
    }

    private func fraction(for x: CGFloat) -> CGFloat {
        min(max((x - stripRect.minX) / max(stripRect.width, 1), 0), 1)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        if abs(p.x - x(for: startFraction)) <= Self.handleWidth + 3 {
            drag = .start
        } else if abs(p.x - x(for: endFraction)) <= Self.handleWidth + 3 {
            drag = .end
        } else {
            drag = .scrub
            onScrub?(fraction(for: p.x))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let drag else { return }
        let f = fraction(for: convert(event.locationInWindow, from: nil).x)
        switch drag {
        case .start:
            startFraction = min(f, endFraction - minGap)
            onTrimChanged?(startFraction, endFraction, true)
        case .end:
            endFraction = max(f, startFraction + minGap)
            onTrimChanged?(startFraction, endFraction, false)
        case .scrub:
            onScrub?(min(max(f, startFraction), endFraction))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    override func resetCursorRects() {
        for handle in [startFraction, endFraction] {
            addCursorRect(
                NSRect(x: x(for: handle) - Self.handleWidth, y: 0,
                       width: Self.handleWidth * 2, height: bounds.height),
                cursor: .resizeLeftRight)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let strip = stripRect
        let clip = NSBezierPath(roundedRect: strip, xRadius: 6, yRadius: 6)

        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSColor.black.withAlphaComponent(0.85).setFill()
        strip.fill()
        if !thumbnails.isEmpty {
            let slot = strip.width / CGFloat(thumbnails.count)
            for (i, thumb) in thumbnails.enumerated() {
                let cell = NSRect(
                    x: strip.minX + CGFloat(i) * slot, y: strip.minY,
                    width: slot + 0.5, height: strip.height)
                // Aspect-fill each slot from the thumb's centre.
                let scale = max(cell.width / CGFloat(thumb.width),
                                cell.height / CGFloat(thumb.height))
                let w = CGFloat(thumb.width) * scale
                let h = CGFloat(thumb.height) * scale
                NSImage(cgImage: thumb, size: NSSize(width: w, height: h)).draw(
                    in: NSRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h),
                    from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
            }
        }
        // Dim the cut-away ends.
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSRect(x: strip.minX, y: strip.minY,
               width: x(for: startFraction) - strip.minX, height: strip.height).fill()
        NSRect(x: x(for: endFraction), y: strip.minY,
               width: strip.maxX - x(for: endFraction), height: strip.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Trim frame: top/bottom rails between the handles plus the two grips.
        let selected = NSRect(
            x: x(for: startFraction), y: strip.minY,
            width: x(for: endFraction) - x(for: startFraction), height: strip.height)
        NSColor.controlAccentColor.setFill()
        NSRect(x: selected.minX, y: selected.minY - 2, width: selected.width, height: 2).fill()
        NSRect(x: selected.minX, y: selected.maxY, width: selected.width, height: 2).fill()
        for (fraction, leading) in [(startFraction, true), (endFraction, false)] {
            let hx = x(for: fraction)
            let handle = NSRect(
                x: leading ? hx - Self.handleWidth : hx,
                y: strip.minY - 2, width: Self.handleWidth, height: strip.height + 4)
            let path = NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3)
            NSColor.controlAccentColor.setFill()
            path.fill()
            NSColor.white.setFill()
            NSRect(x: handle.midX - 0.75, y: handle.midY - 7, width: 1.5, height: 14).fill()
        }

        // Playhead, only inside the kept range.
        if playheadFraction >= startFraction, playheadFraction <= endFraction {
            NSColor.white.setFill()
            NSRect(x: x(for: playheadFraction) - 1, y: strip.minY - 4,
                   width: 2, height: strip.height + 8).fill()
        }
    }
}
