import AppKit
import UniformTypeIdentifiers

/// Everything that happens to a capture after the pixels exist: sound,
/// clipboard, disk, quick-access overlay, annotator, pins, OCR, recents.
@MainActor
final class OutputRouter {
    static let shared = OutputRouter()

    private(set) var recents: [URL] = []
    var onRecentsChanged: (() -> Void)?

    private init() {}

    // MARK: Delivery (the after-capture pipeline)

    /// A scrolling composite (many stitched screen-heights) is large enough
    /// that a single PNG/JPEG encode costs seconds. Above this pixel count the
    /// encode moves off the main thread behind a busy toast so the menu bar,
    /// overlays and open windows stay responsive; smaller captures encode
    /// inline (imperceptible) to keep delivery instant.
    private static let heavyEncodePixels = 10_000_000

    func deliver(_ still: StillCapture) {
        let settings = Settings.shared
        if settings.playSound { playCaptureSound() }

        // "Every sink off" still persists — a capture that goes nowhere is lost.
        let persist = settings.saveToDisk
            || (!settings.copyToClipboard && !settings.showQuickAccess)
        let persistFormat: ImageFormat? = persist
            ? (still.hasAlpha ? .png : settings.imageFormat)
            : nil
        let needClipboardPNG = settings.copyToClipboard

        // Heavy composites encode off-main so the seconds-long encode doesn't
        // freeze the app with no feedback; everything after the bytes exist
        // (record write, clipboard, QAO) still runs back on the main thread.
        if still.image.width * still.image.height > Self.heavyEncodePixels,
           persistFormat != nil || needClipboardPNG {
            Toast.show("Processing capture…", symbol: "hourglass", duration: 4.0)
            let image = still.image
            let scale = still.scale
            let downscaleRetina = settings.downscaleRetina
            DispatchQueue.global(qos: .userInitiated).async {
                let encoded = Self.encode(
                    image: image, scale: scale, downscaleRetina: downscaleRetina,
                    persistFormat: persistFormat, needClipboardPNG: needClipboardPNG)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.finishDeliver(
                            still, persistFormat: persistFormat, persist: encoded.persist,
                            clipboardPNG: encoded.clipboardPNG, settings: settings)
                    }
                }
            }
            return
        }

        let encoded = Self.encode(
            image: still.image, scale: still.scale, downscaleRetina: settings.downscaleRetina,
            persistFormat: persistFormat, needClipboardPNG: needClipboardPNG)
        finishDeliver(
            still, persistFormat: persistFormat, persist: encoded.persist,
            clipboardPNG: encoded.clipboardPNG, settings: settings)
    }

    /// The tail of `deliver(_:)` — runs on the main thread with the pixels
    /// already encoded (inline for small stills, off-main for composites).
    private func finishDeliver(
        _ still: StillCapture, persistFormat: ImageFormat?,
        persist persistData: Data?, clipboardPNG: Data?, settings: Settings
    ) {
        var still = still
        var delivered = DeliveredCapture(payload: .still(still), fileURL: nil)
        // Persist before copying: the pasteboard's file-URL representation
        // must point at a file that already exists or Finder paste breaks.
        if let format = persistFormat, let data = persistData,
           let record = SentryStore.shared.createStillRecord(
               still, data: data,
               fileName: nextFileName(ext: format.fileExtension, origin: still.origin),
               mimeType: format.mimeType
           ) {
            still.recordID = record.id
            delivered = DeliveredCapture(
                payload: .still(still), fileURL: record.mediaURL, recordID: record.id)
            addRecent(record.mediaURL)
        }
        if settings.copyToClipboard {
            copyToClipboard(still, fileURL: delivered.fileURL, pngData: clipboardPNG)
        }
        if settings.showQuickAccess {
            QuickAccessOverlay.shared.push(delivered)
        }
    }

    func deliver(_ video: VideoCapture) {
        let settings = Settings.shared
        var delivered = DeliveredCapture(payload: .video(video), fileURL: nil)
        // Recordings always land in the store: move from the temp location.
        if let record = SentryStore.shared.createVideoRecord(
            tempURL: video.url,
            fileName: nextFileName(ext: video.isGIF ? "gif" : "mp4", origin: video.origin),
            isGIF: video.isGIF,
            origin: video.origin,
            durationSeconds: video.durationSeconds
        ) {
            delivered.fileURL = record.mediaURL
            delivered.recordID = record.id
            addRecent(record.mediaURL)
        } else {
            // Store already toasted; leave the temp file reachable.
            delivered.fileURL = video.url
        }
        if settings.copyToClipboard, let url = delivered.fileURL {
            copyFileURL(url)
        }
        if settings.playSound { playCaptureSound() }
        if settings.showQuickAccess {
            QuickAccessOverlay.shared.push(delivered)
        }
    }

    /// The single finalisation path for edited captures — annotator Save and
    /// QAO/pin re-saves land here so the capture's record updates in place
    /// (and the integration surface sees one evolving record, not forks).
    /// Creates a record when the capture never persisted in the first place.
    @discardableResult
    func reExport(
        _ still: StillCapture, annotationCount: Int? = nil
    ) -> (url: URL, recordID: String)? {
        if let id = still.recordID, let manifest = SentryStore.shared.loadManifest(for: id) {
            // Transparency forces PNG even when the record was JPEG — a
            // remove-bg or spilled-margin edit would flatten to black otherwise.
            let format: ImageFormat = still.hasAlpha
                ? .png
                : (manifest.media.type == "image/jpeg" ? .jpg : .png)
            guard let data = encode(still, format: format),
                  let url = SentryStore.shared.updateStillMedia(
                      recordID: id, still: still, data: data,
                      annotationCount: annotationCount, mimeType: format.mimeType)
            else { return nil }
            return (url, id)
        }
        let format: ImageFormat = still.hasAlpha ? .png : Settings.shared.imageFormat
        guard let data = encode(still, format: format) else { return nil }
        guard let record = SentryStore.shared.createStillRecord(
            still, data: data,
            fileName: nextFileName(ext: format.fileExtension),
            mimeType: format.mimeType
        ) else { return nil }
        addRecent(record.mediaURL)
        return (record.mediaURL, record.id)
    }

    // MARK: Clipboard

    /// One pasteboard item, several representations, so every paste target
    /// picks what it understands: Finder takes the file URL, Slack/Chromium
    /// take PNG, older Cocoa apps take TIFF. Pass pngData to reuse an
    /// already-encoded image instead of encoding again.
    func copyToClipboard(_ still: StillCapture, fileURL: URL? = nil, pngData: Data? = nil) {
        guard let png = pngData ?? encode(still, format: .png) else { return }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        // Skip the TIFF representation on very large images (scrolling
        // composites) — it materialises width x height x 4 uncompressed in the
        // pasteboard server, and modern paste targets all take PNG.
        if still.image.width * still.image.height < 30_000_000,
           let tiff = NSBitmapImageRep(cgImage: still.image).tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        if let fileURL {
            item.setString(fileURL.absoluteString, forType: .fileURL)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    func copyFileURL(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    // MARK: Disk

    @discardableResult
    func save(_ still: StillCapture) -> URL? {
        let format = Settings.shared.imageFormat
        let url = nextFileURL(ext: format.fileExtension)
        guard write(still, to: url, format: format) else { return nil }
        addRecent(url)
        return url
    }

    func saveAs(_ still: StillCapture, over window: NSWindow?) {
        let panel = NSSavePanel()
        let format = Settings.shared.imageFormat
        panel.allowedContentTypes = [format == .png ? UTType.png : UTType.jpeg]
        panel.nameFieldStringValue = nextFileName(ext: format.fileExtension)
        panel.directoryURL = Settings.shared.saveDirectory
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if self.write(still, to: url, format: format) {
                self.addRecent(url)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    func write(_ still: StillCapture, to url: URL, format: ImageFormat) -> Bool {
        guard let data = encode(still, format: format) else { return false }
        return writeData(data, to: url)
    }

    private func writeData(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return true
        } catch {
            NSLog("save failed: \(error)")
            Toast.show("Could not save capture", symbol: "exclamationmark.triangle")
            return false
        }
    }

    /// Off-main-safe PNG encoder for background caching (the QAO pre-encodes
    /// drag payloads so drags start instantly). Pure function of its inputs;
    /// mirrors encode(_:format:) semantics for PNG.
    nonisolated static func encodePNG(
        image: CGImage, dpiScale: CGFloat, downscaleTo1x: Bool = false
    ) -> Data? {
        var image = image
        var scale = dpiScale
        if downscaleTo1x, dpiScale > 1, let smaller = downscale(image, by: dpiScale) {
            image = smaller
            scale = 1
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72.0 * scale,
            kCGImagePropertyDPIHeight: 72.0 * scale,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    func encode(_ still: StillCapture, format: ImageFormat) -> Data? {
        Self.encode(
            image: still.image, scale: still.scale,
            downscaleRetina: Settings.shared.downscaleRetina, format: format)
    }

    /// Off-main-safe encoder. Pure function of its inputs (the downscale flag
    /// is read on the main thread and passed in) so the delivery pipeline can
    /// run a heavy composite encode on a background queue.
    nonisolated static func encode(
        image: CGImage, scale: CGFloat, downscaleRetina: Bool, format: ImageFormat
    ) -> Data? {
        var image = image
        var scale = scale
        if downscaleRetina, scale > 1, let smaller = downscale(image, by: scale) {
            image = smaller
            scale = 1
        }
        let type: UTType = format == .png ? .png : .jpeg
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        // DPI 72 x scale makes Preview report the point size, like the system
        // screenshot tool does.
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72.0 * scale,
            kCGImagePropertyDPIHeight: 72.0 * scale,
        ]
        if format == .jpg {
            props[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Produces the bytes the delivery pipeline needs in one pass: the persist
    /// encoding (in the record's format) and, when the clipboard is a sink, a
    /// PNG for the pasteboard — reusing the persist bytes when it is already
    /// PNG so a composite encodes at most twice, never three times.
    nonisolated static func encode(
        image: CGImage, scale: CGFloat, downscaleRetina: Bool,
        persistFormat: ImageFormat?, needClipboardPNG: Bool
    ) -> (persist: Data?, clipboardPNG: Data?) {
        let persist = persistFormat.flatMap {
            encode(image: image, scale: scale, downscaleRetina: downscaleRetina, format: $0)
        }
        var clipboardPNG: Data?
        if needClipboardPNG {
            clipboardPNG = persistFormat == .png
                ? persist
                : encode(image: image, scale: scale, downscaleRetina: downscaleRetina, format: .png)
        }
        return (persist, clipboardPNG)
    }

    nonisolated private static func downscale(_ image: CGImage, by scale: CGFloat) -> CGImage? {
        let w = Int(CGFloat(image.width) / scale)
        let h = Int(CGFloat(image.height) / scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Filenames

    /// The prefix doubles as a template: {date} {time} {app} {counter}
    /// tokens expand when present; a plain prefix keeps the classic
    /// "Prefix yyyy-MM-dd at HH.mm.ss" shape. The untouched factory default
    /// gets smart names instead: the captured window's title (or app name)
    /// says WHAT was captured — "Setup Cockpit Monitor Stand at 21.47.png"
    /// beats a wall of identical prefixes with only a timestamp changing.
    func nextFileName(ext: String, origin: CaptureOrigin? = nil) -> String {
        let template = Settings.shared.filenamePrefix
        let appName = origin?.appName
        let fmt = DateFormatter()
        var name: String
        if template == "Sentry Capture", let smart = Self.smartNameStem(origin) {
            fmt.dateFormat = "HH.mm"
            name = "\(smart) at \(fmt.string(from: Date()))"
        } else if template.contains("{") {
            fmt.dateFormat = "yyyy-MM-dd"
            let date = fmt.string(from: Date())
            fmt.dateFormat = "HH.mm.ss"
            let time = fmt.string(from: Date())
            name = template
                .replacingOccurrences(of: "{date}", with: date)
                .replacingOccurrences(of: "{time}", with: time)
                .replacingOccurrences(of: "{app}", with: appName ?? "")
            if name.contains("{counter}") {
                let counter = UserDefaults.standard.integer(forKey: "filenameCounter") + 1
                UserDefaults.standard.set(counter, forKey: "filenameCounter")
                name = name.replacingOccurrences(of: "{counter}", with: String(counter))
            }
            // Empty tokens (no app name) leave double spaces behind.
            while name.contains("  ") {
                name = name.replacingOccurrences(of: "  ", with: " ")
            }
            name = name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "Capture" }
        } else {
            fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            name = "\(template) \(fmt.string(from: Date()))"
        }
        // App names can carry path-hostile characters.
        name = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
        return "\(name).\(ext)"
    }

    /// Window title (what was captured) beats app name (what was frontmost);
    /// both trimmed to something a Finder column can show.
    private static func smartNameStem(_ origin: CaptureOrigin?) -> String? {
        guard let origin else { return nil }
        var stem = origin.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stem.isEmpty { stem = origin.appName?.trimmingCharacters(in: .whitespaces) ?? "" }
        guard !stem.isEmpty else { return nil }
        stem = stem.components(separatedBy: .newlines).first ?? stem
        if stem.count > 60 { stem = String(stem.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return stem
    }

    func nextFileURL(ext: String) -> URL {
        var url = Settings.shared.saveDirectory.appendingPathComponent(nextFileName(ext: ext))
        // Burst captures within one second: suffix rather than overwrite.
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = nextFileName(ext: ext).replacingOccurrences(of: ".\(ext)", with: " \(n).\(ext)")
            url = Settings.shared.saveDirectory.appendingPathComponent(base)
            n += 1
        }
        return url
    }

    // MARK: Actions invoked from QAO / annotator / menu

    func openAnnotator(_ still: StillCapture) {
        AnnotatorController.shared.open(still)
    }

    func pin(_ still: StillCapture) {
        PinController.shared.pin(still)
    }

    func copyText(from still: StillCapture) {
        Task { @MainActor in
            do {
                let text = try await OCR.recognizeText(in: still.image)
                if text.isEmpty {
                    if let payload = try? await OCR.decodeBarcode(in: still.image), !payload.isEmpty {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(payload, forType: .string)
                        Toast.show("QR code copied", symbol: "qrcode.viewfinder")
                        return
                    }
                    Toast.show("No text found", symbol: "text.viewfinder")
                } else {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    Toast.show("Text copied", symbol: "text.viewfinder")
                }
            } catch {
                Toast.show("Text recognition failed", symbol: "exclamationmark.triangle")
            }
        }
    }

    // MARK: Recents

    private func addRecent(_ url: URL) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        if recents.count > 10 { recents.removeLast(recents.count - 10) }
        onRecentsChanged?()
    }

    /// Call when a capture file is trashed so the menu doesn't point at it.
    func removeRecent(_ url: URL) {
        recents.removeAll { $0 == url }
        onRecentsChanged?()
    }

    /// A rename keeps the capture's place in the Recents menu.
    func replaceRecent(_ old: URL, with new: URL) {
        if let index = recents.firstIndex(of: old) {
            recents[index] = new
            onRecentsChanged?()
        }
    }

    // MARK: Sound

    private lazy var captureSound: NSSound? = {
        // The system screenshot sound lives on a private path (verified
        // present on macOS 26.5); fall back to a stock alert sound if a
        // future release moves it. Keep the strong reference — NSSound stops
        // if deallocated mid-play.
        let grabPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        if FileManager.default.fileExists(atPath: grabPath),
           let sound = NSSound(contentsOfFile: grabPath, byReference: true) {
            return sound
        }
        return NSSound(named: "Pop")
    }()

    private func playCaptureSound() {
        captureSound?.stop()
        captureSound?.play()
    }
}
