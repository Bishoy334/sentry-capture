import AppKit
import SwiftUI

// MARK: - Controller

/// The browse surface for the capture store: every record under
/// ~/Sentry/captures, persistent across relaunches, filterable, re-openable
/// (stills with a .sentryshot project restore as live annotations).
@MainActor
final class HistoryController: NSObject, NSWindowDelegate {
    static let shared = HistoryController()

    private var window: NSWindow?
    private var holdsActivation = false

    private override init() {
        super.init()
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            w.title = "Capture History"
            w.contentViewController = NSHostingController(rootView: HistoryView())
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 780, height: 540))
            w.contentMinSize = NSSize(width: 520, height: 320)
            w.center()
            w.delegate = self
            window = w
        }
        if holdsActivation {
            NSApp.activate()
        } else {
            holdsActivation = true
            AppActivation.acquire()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        if holdsActivation {
            holdsActivation = false
            AppActivation.release()
        }
    }
}

// MARK: - Data

struct HistoryRecord: Identifiable {
    let id: String
    let manifest: SentryManifest
    let directory: URL

    var mediaURL: URL { directory.appendingPathComponent(manifest.media.path) }
    var isVideo: Bool { manifest.kind == "recording" }

    var created: Date? {
        ISO8601DateFormatter().date(from: manifest.createdAt)
    }
}

extension SentryStore {
    func listRecords() -> [HistoryRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { dir -> HistoryRecord? in
                guard let manifest = loadManifest(for: dir.lastPathComponent) else { return nil }
                return HistoryRecord(id: manifest.id, manifest: manifest, directory: dir)
            }
            // ISO-8601 with a fixed offset sorts lexicographically.
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    func trashRecord(_ record: HistoryRecord) {
        try? FileManager.default.trashItem(at: record.directory, resultingItemURL: nil)
        OutputRouter.shared.removeRecent(record.mediaURL)
    }

    /// Retention policy: records older than the configured window move to the
    /// Bin (recoverable, never deleted outright). Runs at launch and on a
    /// slow timer — the app lives in the menu bar for weeks.
    func sweepExpiredRecords() {
        let days = Settings.shared.retentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var swept = 0
        for record in listRecords() {
            guard let created = record.created, created < cutoff else { continue }
            trashRecord(record)
            swept += 1
        }
        if swept > 0 {
            NSLog("retention sweep: moved \(swept) capture(s) older than \(days)d to the Bin")
        }
    }
}

/// Grid thumbnails decode downsampled — never the full capture.
enum HistoryThumbs {
    nonisolated static func load(url: URL, maxPixels: CGFloat = 480) async -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Views

private struct HistoryView: View {
    enum Filter: String, CaseIterable {
        case all = "All"
        case screenshots = "Screenshots"
        case scrolls = "Scrolling"
        case recordings = "Recordings"

        func matches(_ record: HistoryRecord) -> Bool {
            switch self {
            case .all: return true
            case .screenshots: return record.manifest.kind == "screenshot" || record.manifest.kind == "window"
            case .scrolls: return record.manifest.kind == "scroll"
            case .recordings: return record.manifest.kind == "recording"
            }
        }
    }

    @State private var records: [HistoryRecord] = []
    @State private var filter: Filter = .all
    @State private var searchText = ""

    private var filtered: [HistoryRecord] {
        records.filter { record in
            guard filter.matches(record) else { return false }
            let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
            guard !query.isEmpty else { return true }
            // OCR text makes captures findable by what's IN them — the whole
            // point of storing it in the manifest.
            let haystacks = [
                record.manifest.ocrText,
                record.manifest.source?.appName,
                record.manifest.source?.windowTitle,
                record.manifest.media.path,
                record.manifest.notes,
            ]
            return haystacks.contains { $0?.lowercased().contains(query) == true }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Search text in captures", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 260)
                Spacer()
                Text("\(filtered.count) capture\(filtered.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.open(SentryStore.shared.root)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open captures folder")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "camera.on.rectangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No captures yet")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(filtered) { record in
                            HistoryCard(record: record, onChange: reload)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
        ) { note in
            // Captures land while the panel is open in the background —
            // refresh whenever it comes back to front.
            if (note.object as? NSWindow)?.title == "Capture History" { reload() }
        }
    }

    private func reload() {
        records = SentryStore.shared.listRecords()
    }
}

private struct HistoryCard: View {
    let record: HistoryRecord
    let onChange: () -> Void

    @State private var thumbnail: NSImage?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.4))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: record.isVideo ? "film" : "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                }
                if record.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 5) {
                Image(systemName: kindSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.created.map { Self.dateFormatter.string(from: $0) } ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if record.manifest.annotations?.project != nil {
                    Image(systemName: "pencil.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Re-editable")
                }
                if let w = record.manifest.media.width, let h = record.manifest.media.height {
                    Text("\(w)×\(h)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if let app = record.manifest.source?.appName {
                Text(app)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button("Open") { open() }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([record.mediaURL])
            }
            Button("Copy File") {
                OutputRouter.shared.copyFileURL(record.mediaURL)
            }
            let destinations = SentryRegistry.destinations()
            if !destinations.isEmpty {
                Menu("Send to") {
                    ForEach(destinations, id: \.app) { destination in
                        Button(destination.name) {
                            SentryRegistry.send(recordID: record.id, to: destination)
                        }
                    }
                }
            }
            Divider()
            Button("Move to Bin", role: .destructive) {
                SentryStore.shared.trashRecord(record)
                onChange()
            }
        }
        .task(id: record.id) {
            thumbnail = await HistoryThumbs.load(url: record.mediaURL)
        }
    }

    private var kindSymbol: String {
        switch record.manifest.kind {
        case "recording": return "record.circle"
        case "scroll": return "arrow.up.and.down"
        case "window": return "macwindow"
        default: return "camera.viewfinder"
        }
    }

    private func open() {
        SentryRegistry.openRecord(id: record.id)
    }
}
