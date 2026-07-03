import AppKit
import UniformTypeIdentifiers

/// Phase G batch mode: a drop-zone window, not an editor. N image files in,
/// one export config over all of them, per-file status out. Pure reuse of
/// the ImageExporter pipeline.
@MainActor
final class BatchConvertController: NSObject, NSWindowDelegate {
    static let shared = BatchConvertController()

    private var window: NSWindow?
    private var view: BatchConvertView?

    private override init() {
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let content = BatchConvertView()
        let w = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        w.title = "Batch Convert"
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 460, height: 440))
        w.contentMinSize = NSSize(width: 400, height: 320)
        w.center()
        w.delegate = self
        window = w
        view = content
        AppActivation.acquire()
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        view = nil
        AppActivation.release()
    }
}

// MARK: - View

@MainActor
private final class BatchConvertView: NSView {
    private struct Item {
        let url: URL
        let label: NSTextField
        let status: NSTextField
    }

    private var items: [Item] = []
    private var converting = false

    private let formatPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let qualitySlider = NSSlider(value: 0.85, minValue: 0.3, maxValue: 1, target: nil, action: nil)
    private let metadataCheck = NSButton(checkboxWithTitle: "Remove metadata", target: nil, action: nil)
    private let presetPopup = NSPopUpButton()
    private let listStack = NSStackView()
    private let placeholder = NSTextField(labelWithString: "Drop images here")
    private let summaryLabel = NSTextField(labelWithString: "")
    private var convertButton: NSButton!
    private var clearButton: NSButton!

    private static let sizeOptions: [(String, CGFloat)] = [
        ("Original size", 1), ("75%", 0.75), ("50%", 0.5), ("25%", 0.25),
    ]

    init() {
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            return l
        }

        presetPopup.addItem(withTitle: "Custom")
        for preset in ExportPreset.loadAll() {
            presetPopup.addItem(withTitle: preset.name)
        }
        presetPopup.target = self
        presetPopup.action = #selector(presetPicked)
        presetPopup.isHidden = presetPopup.numberOfItems == 1   // no presets saved yet

        for f in ExportFormat.allCases {
            formatPopup.addItem(withTitle: f.label)
        }
        for (title, _) in Self.sizeOptions {
            sizePopup.addItem(withTitle: title)
        }
        qualitySlider.controlSize = .small
        qualitySlider.toolTip = "Quality (lossy formats)"
        qualitySlider.translatesAutoresizingMaskIntoConstraints = false
        qualitySlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        metadataCheck.controlSize = .small
        metadataCheck.state = .on

        let controls = NSStackView(views: [
            presetPopup, formatPopup, sizePopup, qualitySlider, metadataCheck,
        ])
        controls.orientation = .horizontal
        controls.spacing = 8

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = HUDStyle.hairline.cgColor
        let doc = BatchFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        doc.addSubview(listStack)

        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor

        clearButton = NSButton(title: "Clear", target: self, action: #selector(clearTapped))
        clearButton.controlSize = .small
        clearButton.bezelStyle = .accessoryBarAction
        convertButton = NSButton(title: "Convert All", target: self, action: #selector(convertTapped))
        convertButton.bezelStyle = .rounded
        convertButton.keyEquivalent = "\r"
        convertButton.bezelColor = .controlAccentColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [summaryLabel, spacer, clearButton, convertButton])
        footer.orientation = .horizontal
        footer.spacing = 8

        for v in [controls, scroll, placeholder, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 10),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -10),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            doc.bottomAnchor.constraint(equalTo: listStack.bottomAnchor, constant: 8),
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    // MARK: Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        converting ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return false }
        var added = 0
        for url in urls {
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                  !items.contains(where: { $0.url == url }) else { continue }
            addItem(url)
            added += 1
        }
        refreshSummary()
        return added > 0
    }

    private func addItem(_ url: URL) {
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 11)
        name.lineBreakMode = .byTruncatingMiddle
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [name, spacer, status])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        listStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        items.append(Item(url: url, label: name, status: status))
        placeholder.isHidden = true
    }

    private func refreshSummary() {
        summaryLabel.stringValue = items.isEmpty ? "" : "\(items.count) files"
    }

    // MARK: Actions

    @objc private func presetPicked() {
        let index = presetPopup.indexOfSelectedItem
        let presets = ExportPreset.loadAll()
        guard index >= 1, presets.indices.contains(index - 1) else { return }
        let preset = presets[index - 1]
        formatPopup.selectItem(
            at: ExportFormat.allCases.firstIndex(of: preset.format) ?? 0)
        qualitySlider.doubleValue = preset.quality
        metadataCheck.state = preset.removeMetadata ? .on : .off
    }

    @objc private func clearTapped() {
        guard !converting else { return }
        for view in listStack.arrangedSubviews { view.removeFromSuperview() }
        items.removeAll()
        placeholder.isHidden = false
        refreshSummary()
    }

    @objc private func convertTapped() {
        guard !converting, !items.isEmpty else { return }
        converting = true
        convertButton.isEnabled = false
        clearButton.isEnabled = false
        let format = ExportFormat.allCases[formatPopup.indexOfSelectedItem]
        let scale = Self.sizeOptions[sizePopup.indexOfSelectedItem].1
        let quality = qualitySlider.doubleValue
        let stripMetadata = metadataCheck.state == .on

        Task { @MainActor [weak self] in
            guard let self else { return }
            var done = 0
            var failed = 0
            for item in items {
                item.status.stringValue = "…"
                item.status.textColor = .secondaryLabelColor
                let url = item.url
                let result: String? = await Task.detached(priority: .userInitiated) {
                    BatchPipeline.convert(
                        url: url, format: format, scale: scale,
                        quality: quality, stripMetadata: stripMetadata)
                }.value
                if let name = result {
                    item.status.stringValue = "→ \(name)"
                    item.status.textColor = .secondaryLabelColor
                    done += 1
                } else {
                    item.status.stringValue = "failed"
                    item.status.textColor = .systemRed
                    failed += 1
                }
                summaryLabel.stringValue = "\(done + failed) of \(items.count)"
            }
            summaryLabel.stringValue = failed == 0
                ? "Done — \(done) converted"
                : "Done — \(done) converted, \(failed) failed"
            converting = false
            convertButton.isEnabled = true
            clearButton.isEnabled = true
        }
    }

}

/// The per-file work, UI-free (probe-testable). Output lands beside the
/// source; a name collision (same format, no resize) gets a "converted"
/// suffix rather than overwriting the original.
enum BatchPipeline {
    static func convert(
        url: URL, format: ExportFormat, scale: CGFloat,
        quality: Double, stripMetadata: Bool
    ) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        if scale < 1 {
            guard let resized = ImageExporter.resized(cg, to: CGSize(
                width: max(CGFloat(cg.width) * scale, 1).rounded(),
                height: max(CGFloat(cg.height) * scale, 1).rounded())) else { return nil }
            cg = resized
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = props?[kCGImagePropertyDPIWidth] as? Double ?? 72
        guard let data = ImageExporter.encode(
            cg, format: format, quality: quality,
            dpiScale: stripMetadata ? nil : CGFloat(dpi / 72)) else { return nil }
        var target = url.deletingPathExtension().appendingPathExtension(format.fileExtension)
        if target == url || FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingPathExtension()
                .appendingPathExtension("converted.\(format.fileExtension)")
        }
        do {
            try data.write(to: target)
            return target.lastPathComponent
        } catch {
            return nil
        }
    }
}

/// Scroll document that stacks rows top-down.
private final class BatchFlippedView: NSView {
    override var isFlipped: Bool { true }
}
