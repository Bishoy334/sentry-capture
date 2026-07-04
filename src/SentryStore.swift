import AppKit
import CryptoKit

/// The sentry.capture/v1 record — the envelope fields are the generic Sentry
/// record shape every ecosystem app shares (see SENTRY_SCHEMA.md); the body
/// fields are capture-specific.
struct SentryManifest: Codable {
    var schema = "sentry.capture/v1"
    let id: String
    var app = "sentry.capture"
    var kind: String
    let createdAt: String
    var modifiedAt: String?
    var source: Source?
    var tags: [String] = []
    var notes: String?
    var hash: String?

    var media: Media
    var durationSeconds: Double?
    var ocrText: String?
    var annotations: Annotations?

    struct Media: Codable {
        var path: String
        var type: String
        var width: Int?
        var height: Int?
        var bytes: Int
    }

    struct Source: Codable {
        var appBundleId: String?
        var appName: String?
        var windowTitle: String?
        var display: UInt32?
    }

    struct Annotations: Codable {
        var count: Int
        var project: String?
    }
}

/// The local-first capture store: one folder per record under the captures
/// root, media + manifest.json sidecar. This is the integration surface —
/// other Sentry apps consume these folders directly.
@MainActor
final class SentryStore {
    static let shared = SentryStore()

    private init() {}

    var root: URL { Settings.shared.saveDirectory }

    struct Record {
        let id: String
        let mediaURL: URL
    }

    // MARK: Creation

    /// Media data is already encoded (the router encodes once and shares the
    /// bytes between disk and clipboard).
    func createStillRecord(
        _ still: StillCapture, data: Data, fileName: String, mimeType: String
    ) -> Record? {
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let mediaURL = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: mediaURL)
        } catch {
            NSLog("record write failed: \(error)")
            Toast.show("Could not save capture", symbol: "exclamationmark.triangle")
            return nil
        }

        let manifest = SentryManifest(
            id: id,
            kind: Self.kind(for: still.source),
            createdAt: Self.timestamp(),
            source: still.origin?.manifestSource,
            media: SentryManifest.Media(
                path: fileName, type: mimeType,
                width: still.image.width, height: still.image.height,
                bytes: data.count
            )
        )
        writeManifest(manifest, in: dir)
        completeInBackground(id: id, mediaData: data, image: still.image)
        return Record(id: id, mediaURL: mediaURL)
    }

    /// Moves a finished recording from its temp location into a fresh record.
    func createVideoRecord(
        tempURL: URL, fileName: String, isGIF: Bool,
        origin: CaptureOrigin?, durationSeconds: Double?
    ) -> Record? {
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let mediaURL = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tempURL, to: mediaURL)
        } catch {
            NSLog("recording record write failed: \(error)")
            Toast.show("Could not save recording", symbol: "exclamationmark.triangle")
            return nil
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: mediaURL.path)[.size] as? Int) ?? 0
        let manifest = SentryManifest(
            id: id,
            kind: "recording",
            createdAt: Self.timestamp(),
            source: origin?.manifestSource,
            media: SentryManifest.Media(
                path: fileName, type: isGIF ? "image/gif" : "video/mp4",
                width: nil, height: nil, bytes: bytes
            ),
            durationSeconds: durationSeconds
        )
        writeManifest(manifest, in: dir)
        hashFileInBackground(id: id, mediaURL: mediaURL)
        return Record(id: id, mediaURL: mediaURL)
    }

    // MARK: Re-export (annotator / QAO / pin saves)

    /// Overwrites the record's media with an edited export and stamps
    /// modifiedAt. The annotator's Save lands here so downstream consumers
    /// see one record whose content evolved, not a fork.
    func updateStillMedia(
        recordID: String, still: StillCapture, data: Data, annotationCount: Int?,
        mimeType: String? = nil
    ) -> URL? {
        let dir = root.appendingPathComponent(recordID, isDirectory: true)
        guard var manifest = loadManifest(in: dir) else { return nil }
        // Format change (a JPEG record gaining transparency re-exports as
        // PNG) — move the media path so extension and mime stay in agreement.
        if let mimeType, mimeType != manifest.media.type {
            let ext = mimeType == "image/png" ? "png" : "jpg"
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent(manifest.media.path))
            manifest.media.path =
                (manifest.media.path as NSString).deletingPathExtension + "." + ext
            manifest.media.type = mimeType
        }
        let mediaURL = dir.appendingPathComponent(manifest.media.path)
        do {
            try data.write(to: mediaURL)
        } catch {
            NSLog("record media update failed: \(error)")
            return nil
        }
        manifest.modifiedAt = Self.timestamp()
        manifest.media.width = still.image.width
        manifest.media.height = still.image.height
        manifest.media.bytes = data.count
        manifest.hash = nil // stale until the background pass recomputes
        if let annotationCount {
            manifest.annotations = SentryManifest.Annotations(
                count: annotationCount, project: manifest.annotations?.project)
        }
        writeManifest(manifest, in: dir)
        completeInBackground(id: recordID, mediaData: data, image: still.image)
        return mediaURL
    }

    /// Replaces a recording's media with a trim-editor export and stamps
    /// modifiedAt — the video counterpart of updateStillMedia.
    func updateVideoMedia(recordID: String, tempURL: URL, durationSeconds: Double?) -> URL? {
        let dir = recordDirectory(for: recordID)
        guard var manifest = loadManifest(in: dir) else { return nil }
        let mediaURL = dir.appendingPathComponent(manifest.media.path)
        do {
            _ = try FileManager.default.replaceItemAt(mediaURL, withItemAt: tempURL)
        } catch {
            NSLog("record video update failed: \(error)")
            return nil
        }
        manifest.modifiedAt = Self.timestamp()
        manifest.media.bytes =
            (try? FileManager.default.attributesOfItem(atPath: mediaURL.path)[.size] as? Int) ?? 0
        manifest.durationSeconds = durationSeconds
        manifest.hash = nil // stale until the background pass recomputes
        writeManifest(manifest, in: dir)
        hashFileInBackground(id: recordID, mediaURL: mediaURL)
        return mediaURL
    }

    // MARK: Manifest IO

    func recordDirectory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    func loadManifest(for id: String) -> SentryManifest? {
        loadManifest(in: recordDirectory(for: id))
    }

    private func loadManifest(in dir: URL) -> SentryManifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(SentryManifest.self, from: data)
    }

    private func writeManifest(_ manifest: SentryManifest, in dir: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: dir.appendingPathComponent("manifest.json"))
    }

    // MARK: Async completion (hash + OCR)

    /// Hashing and OCR are seconds of work on big captures — the record lands
    /// immediately and these fields fill in behind it.
    private func completeInBackground(id: String, mediaData: Data, image: CGImage) {
        let runOCR = image.width * image.height <= 40_000_000
        Task.detached(priority: .utility) {
            let hash = "sha256:" + SHA256.hash(data: mediaData)
                .map { String(format: "%02x", $0) }.joined()
            let text: String? = runOCR ? try? await OCR.recognizeText(in: image) : nil
            await MainActor.run {
                SentryStore.shared.amendManifest(id: id) { manifest in
                    manifest.hash = hash
                    if let text, !text.isEmpty { manifest.ocrText = text }
                }
            }
        }
    }

    private func hashFileInBackground(id: String, mediaURL: URL) {
        Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: mediaURL) else { return }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let hash = "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
            await MainActor.run {
                SentryStore.shared.amendManifest(id: id) { $0.hash = hash }
            }
        }
    }

    /// Rename the record's media file in place (QAO inline rename). Returns
    /// the new URL, or nil when the move fails (name collision, gone, …).
    func renameMedia(recordID: String, to newFileName: String) -> URL? {
        let dir = recordDirectory(for: recordID)
        guard let manifest = loadManifest(in: dir) else { return nil }
        let old = dir.appendingPathComponent(manifest.media.path)
        let new = dir.appendingPathComponent(newFileName)
        guard old != new else { return old }
        do {
            try FileManager.default.moveItem(at: old, to: new)
        } catch {
            NSLog("rename failed: \(error)")
            return nil
        }
        amendManifest(id: recordID) {
            $0.media.path = newFileName
            $0.modifiedAt = Self.timestamp()
        }
        return new
    }

    func amendManifest(id: String, _ mutate: (inout SentryManifest) -> Void) {
        let dir = recordDirectory(for: id)
        guard var manifest = loadManifest(in: dir) else { return }
        mutate(&manifest)
        writeManifest(manifest, in: dir)
    }

    // MARK: Helpers

    private static func kind(for source: StillSource) -> String {
        switch source {
        case .area, .fullscreen: return "screenshot"
        case .window: return "window"
        case .scrolling: return "scroll"
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
}

extension CaptureOrigin {
    var manifestSource: SentryManifest.Source {
        SentryManifest.Source(
            appBundleId: appBundleID, appName: appName,
            windowTitle: windowTitle, display: displayID)
    }
}
