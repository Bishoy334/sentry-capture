import AppKit

/// A Sentry ecosystem app advertising itself in ~/Sentry/apps/ — see
/// SENTRY_SCHEMA.md. Capture reads these to build its "Send to…" menus;
/// sending is just opening the destination's URL scheme with a record id
/// (the record is already on disk — URLs carry identifiers, never payloads).
struct SentryDestination: Codable {
    let app: String
    let name: String
    var symbol: String?
    let urlScheme: String
    var accepts: [String]?
}

@MainActor
enum SentryRegistry {
    static var appsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Sentry/apps", isDirectory: true)
    }

    /// Destinations that accept capture records. Read fresh each call — the
    /// folder is tiny and apps can appear at any time.
    static func destinations(accepting schema: String = "sentry.capture/v1") -> [SentryDestination] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: appsDirectory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SentryDestination? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(SentryDestination.self, from: data)
            }
            .filter { $0.app != "sentry.capture" }
            .filter { $0.accepts?.contains(schema) ?? false }
            .sorted { $0.name < $1.name }
    }

    /// Hand a capture record to another Sentry app. The whole contract:
    /// the record folder already exists; the URL carries only its id.
    static func send(recordID: String, to destination: SentryDestination) {
        var components = URLComponents()
        components.scheme = destination.urlScheme
        components.host = "receive"
        components.queryItems = [
            URLQueryItem(name: "record", value: recordID),
            URLQueryItem(name: "schema", value: "sentry.capture/v1"),
        ]
        guard let url = components.url else { return }
        if !NSWorkspace.shared.open(url) {
            Toast.show("\(destination.name) is not available", symbol: "exclamationmark.triangle")
        }
    }

    /// Our own capability file — written at launch so the registry pattern
    /// is self-documenting from the first app.
    static func advertiseSelf() {
        let dir = appsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let capability: [String: Any] = [
            "app": "sentry.capture",
            "name": "Sentry Capture",
            "symbol": "camera.viewfinder",
            "urlScheme": "sentry-capture",
            "accepts": [],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: capability, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: dir.appendingPathComponent("sentry.capture.json"))
    }

    // MARK: Inbound URL actions (fixed, validated set — a URL scheme is an
    // input trust boundary; anything unrecognised is dropped)

    static func handle(_ url: URL) {
        guard url.scheme == "sentry-capture" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? [])
                .compactMap { item in item.value.map { (item.name, $0) } })

        switch url.host {
        case "capture":
            let modes: [String: HotkeyAction] = [
                "area": .captureArea, "window": .captureWindow,
                "fullscreen": .captureFullscreen, "scrolling": .scrollingCapture,
                "ocr": .copyText, "pin": .pinArea,
                "record": .recordVideo, "gif": .recordGIF,
            ]
            guard let mode = query["mode"], let action = modes[mode] else {
                NSLog("sentry-capture url: unknown capture mode")
                return
            }
            (NSApp.delegate as? AppDelegate)?.dispatch(action)
        case "open":
            guard let id = query["id"], UUID(uuidString: id) != nil else {
                NSLog("sentry-capture url: invalid record id")
                return
            }
            openRecord(id: id)
        case "settings":
            PreferencesController.shared.show()
        default:
            NSLog("sentry-capture url: unknown action \(url.host ?? "nil")")
        }
    }

    /// Open a record for editing (stills) or reveal it (videos).
    static func openRecord(id: String) {
        guard let manifest = SentryStore.shared.loadManifest(for: id) else {
            Toast.show("Capture not found", symbol: "questionmark.folder")
            return
        }
        let mediaURL = SentryStore.shared.recordDirectory(for: id)
            .appendingPathComponent(manifest.media.path)
        if manifest.media.type.hasPrefix("image/"), manifest.media.type != "image/gif" {
            guard let source = CGImageSourceCreateWithURL(mediaURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                Toast.show("Could not open capture", symbol: "exclamationmark.triangle")
                return
            }
            // DPI metadata carries the point size; default to 2x if absent.
            var scale: CGFloat = 2
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let dpi = props[kCGImagePropertyDPIWidth] as? CGFloat, dpi > 0 {
                scale = dpi / 72.0
            }
            let still = StillCapture(
                image: image, scale: scale, source: .area,
                screenRect: nil, origin: nil, recordID: id)
            AnnotatorController.shared.open(still)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([mediaURL])
        }
    }
}
