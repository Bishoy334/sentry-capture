import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

// MARK: - Formats

/// Export formats — exactly the set this SDK can WRITE (research §5,
/// enumerated at runtime). WebP/JXL are read-only and deliberately absent.
enum ExportFormat: String, CaseIterable, Codable {
    case png, jpeg, heic, avif, tiff, pdf

    var label: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .tiff: return "TIFF"
        case .pdf: return "PDF"
        }
    }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .avif: return UTType("public.avif") ?? .heic
        case .tiff: return .tiff
        case .pdf: return .pdf
        }
    }

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var isLossy: Bool { self == .jpeg || self == .heic || self == .avif }
}

// MARK: - Encoder

enum ImageExporter {
    /// One CGImageDestination path for every format. `dpiScale` nil = bare
    /// pixels, no properties at all (the "remove metadata" behaviour — a
    /// CGImage carries no EXIF, so properties are only ever what we add).
    static func encode(
        _ image: CGImage, format: ExportFormat,
        quality: Double = 0.85, dpiScale: CGFloat? = nil
    ) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, format.utType.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if format.isLossy {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if format == .jpeg {
            // JPEG has no alpha — flatten onto white instead of onto black.
            props[kCGImageDestinationBackgroundColor] = CGColor.white
        }
        if let dpiScale {
            props[kCGImagePropertyDPIWidth] = 72.0 * dpiScale
            props[kCGImagePropertyDPIHeight] = 72.0 * dpiScale
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Lanczos resample to an exact pixel size (research §6 — the pro
    /// default, sharpest downscale).
    static func resized(_ image: CGImage, to target: CGSize) -> CGImage? {
        guard target.width >= 1, target.height >= 1 else { return nil }
        let filter = CIFilter.lanczosScaleTransform()
        let input = CIImage(cgImage: image)
        filter.inputImage = input
        filter.scale = Float(target.height / CGFloat(image.height))
        filter.aspectRatio = Float(
            (target.width / CGFloat(image.width)) / (target.height / CGFloat(image.height)))
        guard let out = filter.outputImage else { return nil }
        let rect = CGRect(x: 0, y: 0, width: target.width.rounded(), height: target.height.rounded())
        return ImagePipeline.ciContext.createCGImage(out.cropped(to: rect), from: rect)
    }

    // MARK: One-shot convert (History / QAO / menu bar)

    @MainActor
    static func convertFlow(
        image: CGImage, dpiScale: CGFloat, suggestedName: String, to format: ExportFormat
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = suggestedName + "." + format.fileExtension
        panel.directoryURL = Settings.shared.saveDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = encode(image, format: format, dpiScale: dpiScale),
              (try? data.write(to: url)) != nil else {
            Toast.show("Could not convert image", symbol: "exclamationmark.triangle")
            return
        }
        Toast.show("Saved as \(format.label)", symbol: "arrow.triangle.2.circlepath")
    }

    @MainActor
    static func convertFlow(fileURL: URL, to format: ExportFormat) {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            Toast.show("Could not read image", symbol: "exclamationmark.triangle")
            return
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = props?[kCGImagePropertyDPIWidth] as? Double ?? 72
        convertFlow(
            image: cg, dpiScale: CGFloat(dpi / 72),
            suggestedName: fileURL.deletingPathExtension().lastPathComponent, to: format)
    }

    /// Menu-bar "Clean Up Clipboard Image": whatever flavour is on the
    /// pasteboard (TIFF, PDF, file URL, promise) round-trips to a clean PNG.
    @MainActor
    static func cleanUpClipboard() {
        let pb = NSPasteboard.general
        guard let img = NSImage(pasteboard: pb),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = encode(cg, format: .png) else {
            Toast.show("No image on the clipboard", symbol: "doc.on.clipboard")
            return
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        pb.writeObjects([item])
        Toast.show("Clipboard is now clean PNG · \(cg.width)×\(cg.height)", symbol: "sparkles")
    }
}

// MARK: - Presets

struct ExportPreset: Codable, Equatable {
    var name: String
    var format: ExportFormat
    /// Output scale in point multiples (@1x/@2x/@3x).
    var scale: Int
    var quality: Double
    var removeMetadata: Bool

    private static let key = "exportPresets"

    static func loadAll() -> [ExportPreset] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ExportPreset].self, from: data)) ?? []
    }

    static func saveAll(_ presets: [ExportPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Export sheet

/// The real export dialog (plan Phase C): live preview + estimated size on
/// the left, format / scale / size / quality / metadata / destination on the
/// right, presets on top.
@MainActor
final class ExportSheetController: NSObject, NSTextFieldDelegate {
    private static var current: ExportSheetController?

    static func present(over parent: NSWindow, image: CGImage, dpiScale: CGFloat) {
        let controller = ExportSheetController(parent: parent, image: image, dpiScale: dpiScale)
        current = controller
        parent.beginSheet(controller.sheet) { _ in current = nil }
    }

    private let parent: NSWindow
    private let source: CGImage
    private let dpiScale: CGFloat
    private let sheet: NSWindow

    private let previewView = NSImageView()
    private let sizeLabel = NSTextField(labelWithString: "…")
    private let presetPopup = NSPopUpButton()
    private let formatPopup = NSPopUpButton()
    private var scaleSeg: NSSegmentedControl!
    private let widthField = NSTextField(string: "")
    private let heightField = NSTextField(string: "")
    private var qualityRow: NSView!
    private let qualitySlider = NSSlider(value: 0.85, minValue: 0.3, maxValue: 1.0, target: nil, action: nil)
    private let qualityValue = NSTextField(labelWithString: "85%")
    private let metadataCheck = NSButton(checkboxWithTitle: "Remove metadata", target: nil, action: nil)
    private let destinationPopup = NSPopUpButton()

    private var format: ExportFormat = .png
    private var outputPx: CGSize
    private var presets = ExportPreset.loadAll()
    /// Latest encode wins; stale results are dropped (same throttle pattern
    /// as the canvas preview).
    private var encodeGeneration = 0
    private var resizeCache: (px: CGSize, image: CGImage)?

    private var aspect: CGFloat { CGFloat(source.width) / CGFloat(source.height) }

    private init(parent: NSWindow, image: CGImage, dpiScale: CGFloat) {
        self.parent = parent
        source = image
        self.dpiScale = dpiScale
        outputPx = CGSize(width: image.width, height: image.height)
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 430),
            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        sheet.contentView = buildContent()
        syncFields()
        refreshOutput()
    }

    // MARK: Layout

    private func buildContent() -> NSView {
        let content = NSView()

        previewView.imageScaling = .scaleProportionallyDown
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        previewView.layer?.cornerRadius = 6
        // The image view's intrinsic size is the image's POINT size — a 3x
        // export would autolayout the whole sheet to thousands of points
        // tall. Pin the frame; the image scales into it.
        previewView.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        previewView.setContentCompressionResistancePriority(.init(1), for: .vertical)
        previewView.setContentHuggingPriority(.init(1), for: .horizontal)
        previewView.setContentHuggingPriority(.init(1), for: .vertical)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .center

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 70).isActive = true
            return l
        }
        func row(_ title: String, _ control: NSView) -> NSStackView {
            let r = NSStackView(views: [label(title), control])
            r.orientation = .horizontal
            r.spacing = 8
            return r
        }

        rebuildPresetPopup()
        presetPopup.target = self
        presetPopup.action = #selector(presetPicked)

        for f in ExportFormat.allCases {
            formatPopup.addItem(withTitle: f.label)
        }
        formatPopup.target = self
        formatPopup.action = #selector(formatPicked)

        scaleSeg = NSSegmentedControl(
            labels: ["1×", "2×", "3×"], trackingMode: .selectOne,
            target: self, action: #selector(scalePicked))
        scaleSeg.selectedSegment = min(max(Int(dpiScale), 1), 3) - 1

        for f in [widthField, heightField] {
            f.delegate = self
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        let by = NSTextField(labelWithString: "×")
        by.textColor = .secondaryLabelColor
        let px = NSTextField(labelWithString: "px")
        px.font = .systemFont(ofSize: 11)
        px.textColor = .secondaryLabelColor
        let sizeRow = NSStackView(views: [widthField, by, heightField, px])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 4

        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.translatesAutoresizingMaskIntoConstraints = false
        qualitySlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        qualityValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        qualityValue.textColor = .secondaryLabelColor
        let qualityStack = NSStackView(views: [qualitySlider, qualityValue])
        qualityStack.orientation = .horizontal
        qualityStack.spacing = 6

        metadataCheck.state = .on   // privacy default (plan: DEFAULT ON)
        metadataCheck.controlSize = .small
        metadataCheck.target = self
        metadataCheck.action = #selector(metadataToggled)

        for title in ["Save to file…", "Copy to clipboard", "File + clipboard"] {
            destinationPopup.addItem(withTitle: title)
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let export = NSButton(title: "Export", target: self, action: #selector(exportTapped))
        export.keyEquivalent = "\r"
        export.bezelColor = .controlAccentColor
        let buttons = NSStackView(views: [cancel, export])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let qRow = row("Quality", qualityStack)
        qualityRow = qRow
        let controls = NSStackView(views: [
            row("Preset", presetPopup),
            row("Format", formatPopup),
            row("Scale", scaleSeg),
            row("Size", sizeRow),
            qRow,
            row("", metadataCheck),
            row("Send to", destinationPopup),
        ])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 12

        for v in [previewView, sizeLabel, controls, buttons] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            previewView.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            previewView.widthAnchor.constraint(equalToConstant: 300),
            previewView.heightAnchor.constraint(equalToConstant: 340),
            previewView.bottomAnchor.constraint(equalTo: sizeLabel.topAnchor, constant: -8),
            sizeLabel.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            sizeLabel.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
            sizeLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            controls.leadingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: 24),
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        return content
    }

    private func rebuildPresetPopup() {
        presetPopup.removeAllItems()
        presetPopup.addItem(withTitle: "Custom")
        if !presets.isEmpty {
            presetPopup.menu?.addItem(.separator())
            for preset in presets {
                presetPopup.addItem(withTitle: preset.name)
            }
        }
        presetPopup.menu?.addItem(.separator())
        presetPopup.addItem(withTitle: "Save Current as Preset…")
    }

    // MARK: State sync

    private func syncFields() {
        widthField.stringValue = "\(Int(outputPx.width))"
        heightField.stringValue = "\(Int(outputPx.height))"
        qualityRow.isHidden = !format.isLossy
        qualityValue.stringValue = "\(Int((qualitySlider.doubleValue * 100).rounded()))%"
    }

    private func selectScaleSegmentIfMatching() {
        let points = CGFloat(source.width) / dpiScale
        scaleSeg.selectedSegment = (1...3).first {
            abs(outputPx.width - points * CGFloat($0)) < 1
        }.map { $0 - 1 } ?? -1
    }

    /// The image at the chosen pixel size (Lanczos when it differs), cached
    /// so a quality drag doesn't re-resample.
    private func currentOutputImage() -> CGImage? {
        if Int(outputPx.width) == source.width, Int(outputPx.height) == source.height {
            return source
        }
        if let cached = resizeCache, cached.px == outputPx { return cached.image }
        guard let resized = ImageExporter.resized(source, to: outputPx) else { return nil }
        resizeCache = (outputPx, resized)
        return resized
    }

    private var outputDPIScale: CGFloat {
        outputPx.width / (CGFloat(source.width) / dpiScale)
    }

    /// Live preview + estimated size: encode off-main, latest state wins.
    /// The preview shows the DECODED encode, so JPEG/HEIC artefacts are real.
    private func refreshOutput() {
        encodeGeneration += 1
        let generation = encodeGeneration
        let fmt = format
        let quality = qualitySlider.doubleValue
        let dpi: CGFloat? = metadataCheck.state == .on ? nil : outputDPIScale
        guard let output = currentOutputImage() else { return }
        sizeLabel.stringValue =
            "\(Int(outputPx.width)) × \(Int(outputPx.height)) px · …"
        Task.detached(priority: .userInitiated) { [weak self] in
            let data = ImageExporter.encode(output, format: fmt, quality: quality, dpiScale: dpi)
            await MainActor.run { [weak self] in
                guard let self, generation == self.encodeGeneration else { return }
                if let data {
                    let bytes = ByteCountFormatter.string(
                        fromByteCount: Int64(data.count), countStyle: .file)
                    sizeLabel.stringValue =
                        "\(Int(outputPx.width)) × \(Int(outputPx.height)) px · ≈ \(bytes)"
                    previewView.image = NSImage(data: data)
                        ?? NSImage(cgImage: output, size: .zero)
                } else {
                    sizeLabel.stringValue = "Could not encode"
                }
            }
        }
    }

    // MARK: Actions

    @objc private func formatPicked() {
        format = ExportFormat.allCases[formatPopup.indexOfSelectedItem]
        presetPopup.selectItem(at: 0)
        syncFields()
        refreshOutput()
    }

    @objc private func scalePicked() {
        let n = CGFloat(scaleSeg.selectedSegment + 1)
        let points = CGFloat(source.width) / dpiScale
        outputPx = CGSize(
            width: (points * n).rounded(),
            height: (CGFloat(source.height) / dpiScale * n).rounded())
        presetPopup.selectItem(at: 0)
        syncFields()
        refreshOutput()
    }

    @objc private func qualityChanged() {
        qualityValue.stringValue = "\(Int((qualitySlider.doubleValue * 100).rounded()))%"
        presetPopup.selectItem(at: 0)
        refreshOutput()
    }

    @objc private func metadataToggled() {
        presetPopup.selectItem(at: 0)
        refreshOutput()
    }

    /// W and H stay ratio-locked — free stretching a screenshot is a
    /// non-goal; typing either dimension recomputes the other.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let value = Double(field.stringValue), value >= 1 else { return }
        if field === widthField {
            outputPx = CGSize(width: value.rounded(), height: (value / aspect).rounded())
            heightField.stringValue = "\(Int(outputPx.height))"
        } else if field === heightField {
            outputPx = CGSize(width: (value * aspect).rounded(), height: value.rounded())
            widthField.stringValue = "\(Int(outputPx.width))"
        } else {
            return
        }
        selectScaleSegmentIfMatching()
        presetPopup.selectItem(at: 0)
        refreshOutput()
    }

    @objc private func presetPicked() {
        let index = presetPopup.indexOfSelectedItem
        if index == presetPopup.numberOfItems - 1 {   // Save Current as Preset…
            presetPopup.selectItem(at: 0)
            savePresetFlow()
            return
        }
        guard index >= 1, presets.indices.contains(index - 1) else { return }
        apply(presets[index - 1])
        presetPopup.selectItem(at: index)
    }

    private func apply(_ preset: ExportPreset) {
        format = preset.format
        formatPopup.selectItem(at: ExportFormat.allCases.firstIndex(of: preset.format) ?? 0)
        qualitySlider.doubleValue = preset.quality
        metadataCheck.state = preset.removeMetadata ? .on : .off
        let n = CGFloat(preset.scale)
        outputPx = CGSize(
            width: (CGFloat(source.width) / dpiScale * n).rounded(),
            height: (CGFloat(source.height) / dpiScale * n).rounded())
        scaleSeg.selectedSegment = preset.scale - 1
        syncFields()
        refreshOutput()
    }

    private func savePresetFlow() {
        let alert = NSAlert()
        alert.messageText = "Save Export Preset"
        alert.informativeText = "Format, scale, quality and metadata choice are saved."
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "e.g. Web @2x"
        nameField.frame = NSRect(x: 0, y: 0, width: 220, height: 22)
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let scale = max(1, min(3, Int((outputDPIScale).rounded())))
        presets.removeAll { $0.name == name }
        presets.append(ExportPreset(
            name: name, format: format, scale: scale,
            quality: qualitySlider.doubleValue,
            removeMetadata: metadataCheck.state == .on))
        ExportPreset.saveAll(presets)
        rebuildPresetPopup()
        presetPopup.selectItem(withTitle: name)
    }

    @objc private func cancelTapped() {
        parent.endSheet(sheet)
    }

    @objc private func exportTapped() {
        guard let output = currentOutputImage(),
              let data = ImageExporter.encode(
                  output, format: format, quality: qualitySlider.doubleValue,
                  dpiScale: metadataCheck.state == .on ? nil : outputDPIScale) else {
            Toast.show("Could not encode image", symbol: "exclamationmark.triangle")
            return
        }
        let wantsFile = destinationPopup.indexOfSelectedItem != 1
        let wantsClipboard = destinationPopup.indexOfSelectedItem != 0
        if wantsClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(format.utType.identifier))
            if format != .png, let png = ImageExporter.encode(output, format: .png) {
                item.setData(png, forType: .png)   // most paste targets speak PNG
            }
            pb.writeObjects([item])
        }
        guard wantsFile else {
            Toast.show("Copied \(format.label)", symbol: "doc.on.clipboard")
            parent.endSheet(sheet)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = OutputRouter.shared.nextFileName(ext: format.fileExtension)
        panel.directoryURL = Settings.shared.saveDirectory
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                do {
                    try data.write(to: url)
                    Toast.show("Exported \(format.label)", symbol: "square.and.arrow.up")
                } catch {
                    Toast.show("Could not save file", symbol: "exclamationmark.triangle")
                }
            }
            parent.endSheet(sheet)
        }
    }
}
