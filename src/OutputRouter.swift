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

    func deliver(_ still: StillCapture) {
        let settings = Settings.shared
        if settings.playSound { playCaptureSound() }

        var still = still
        var delivered = DeliveredCapture(payload: .still(still), fileURL: nil)
        // Persist before copying: the pasteboard's file-URL representation
        // must point at a file that already exists or Finder paste breaks.
        // When both sinks want PNG, encode once and share the bytes — a
        // scrolling composite costs seconds per encode.
        var sharedPNG: Data?
        // "Every sink off" still persists — a capture that goes nowhere is lost.
        let persist = settings.saveToDisk
            || (!settings.copyToClipboard && !settings.showQuickAccess)
        if persist {
            let format = settings.imageFormat
            let data: Data?
            if format == .png {
                sharedPNG = encode(still, format: .png)
                data = sharedPNG
            } else {
                data = encode(still, format: format)
            }
            if let data, let record = SentryStore.shared.createStillRecord(
                still, data: data,
                fileName: nextFileName(ext: format.fileExtension),
                mimeType: format.mimeType
            ) {
                still.recordID = record.id
                delivered = DeliveredCapture(payload: .still(still), fileURL: record.mediaURL)
                addRecent(record.mediaURL)
            }
        }
        if settings.copyToClipboard {
            copyToClipboard(still, fileURL: delivered.fileURL, pngData: sharedPNG)
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
            fileName: nextFileName(ext: video.isGIF ? "gif" : "mp4"),
            isGIF: video.isGIF,
            origin: video.origin,
            durationSeconds: video.durationSeconds
        ) {
            delivered.fileURL = record.mediaURL
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
    func reExport(_ still: StillCapture, annotationCount: Int? = nil) -> URL? {
        if let id = still.recordID, let manifest = SentryStore.shared.loadManifest(for: id) {
            let format: ImageFormat = manifest.media.type == "image/jpeg" ? .jpg : .png
            guard let data = encode(still, format: format) else { return nil }
            return SentryStore.shared.updateStillMedia(
                recordID: id, still: still, data: data, annotationCount: annotationCount)
        }
        let format = Settings.shared.imageFormat
        guard let data = encode(still, format: format) else { return nil }
        guard let record = SentryStore.shared.createStillRecord(
            still, data: data,
            fileName: nextFileName(ext: format.fileExtension),
            mimeType: format.mimeType
        ) else { return nil }
        addRecent(record.mediaURL)
        return record.mediaURL
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
        var image = still.image
        var scale = still.scale
        if Settings.shared.downscaleRetina, still.scale > 1 {
            if let smaller = Self.downscale(image, by: still.scale) {
                image = smaller
                scale = 1
            }
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

    func nextFileName(ext: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(Settings.shared.filenamePrefix) \(fmt.string(from: Date())).\(ext)"
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
