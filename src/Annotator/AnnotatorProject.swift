import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The re-editable annotation document: the clean (un-annotated, possibly
/// cropped) base image plus the annotation array, stored beside a capture's
/// media inside its record folder. Open JSON so any Sentry app can inspect it;
/// the attributed strings are derived data and rebuilt on load.
struct AnnotatorProject {
    static let projectFileName = "capture.sentryshot"
    static let baseFileName = "base.png"

    var scale: CGFloat
    var baseImage: CGImage
    var annotations: [AnnotatorAnnotation]
    var background: AnnotatorBackgroundStyle?

    // MARK: File shape

    private struct File: Codable {
        var schema = "sentry.sentryshot/v1"
        var scale: CGFloat
        var base: String
        var annotations: [Item]
        var background: BackgroundItem?
    }

    private struct BackgroundItem: Codable {
        var fillKind: String            // none | solid | gradient
        var solid: [CGFloat]?
        var gradientIndex: Int?
        var padding: CGFloat
        var cornerRadius: CGFloat
        var shadow: Bool
    }

    private struct Item: Codable {
        var kind: AnnotatorKind
        var rect: [CGFloat]
        var start: [CGFloat]
        var end: [CGFloat]
        var points: [[CGFloat]]
        var colour: [CGFloat]
        var lineWidth: CGFloat
        var string: String?
        var textSize: CGFloat
        var textStyle: Int
        var number: Int
        var redactStyle: Int
        var arrowStyle: Int
    }

    // MARK: Write

    func write(in dir: URL) -> Bool {
        guard let png = OutputRouter.encodePNG(image: baseImage, dpiScale: scale) else {
            return false
        }
        let file = File(
            scale: scale,
            base: Self.baseFileName,
            annotations: annotations.map(Self.item(from:)),
            background: background.flatMap(Self.backgroundItem(from:)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(file) else { return false }
        do {
            try png.write(to: dir.appendingPathComponent(Self.baseFileName))
            try json.write(to: dir.appendingPathComponent(Self.projectFileName))
            return true
        } catch {
            NSLog("sentryshot write failed: \(error)")
            return false
        }
    }

    // MARK: Load

    static func load(from dir: URL) -> AnnotatorProject? {
        guard let json = try? Data(contentsOf: dir.appendingPathComponent(projectFileName)),
              let file = try? JSONDecoder().decode(File.self, from: json) else { return nil }
        let baseURL = dir.appendingPathComponent(file.base)
        guard let source = CGImageSourceCreateWithURL(baseURL as CFURL, nil),
              let base = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return AnnotatorProject(
            scale: file.scale,
            baseImage: base,
            annotations: file.annotations.map(annotation(from:)),
            background: file.background.flatMap(backgroundStyle(from:)))
    }

    // MARK: Mapping

    private static func backgroundItem(from style: AnnotatorBackgroundStyle) -> BackgroundItem? {
        guard style.isVisible else { return nil }
        var item = BackgroundItem(
            fillKind: "none", solid: nil, gradientIndex: nil,
            padding: style.padding, cornerRadius: style.cornerRadius, shadow: style.shadow)
        switch style.fill {
        case .none:
            return nil
        case .solid(let colour):
            let c = colour.usingColorSpace(.sRGB) ?? colour
            item.fillKind = "solid"
            item.solid = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
        case .gradient(let index):
            item.fillKind = "gradient"
            item.gradientIndex = index
        }
        return item
    }

    private static func backgroundStyle(from item: BackgroundItem) -> AnnotatorBackgroundStyle? {
        var style = AnnotatorBackgroundStyle(
            fill: .none, padding: item.padding,
            cornerRadius: item.cornerRadius, shadow: item.shadow)
        switch item.fillKind {
        case "solid":
            guard let c = item.solid, c.count == 4 else { return nil }
            style.fill = .solid(NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3]))
        case "gradient":
            guard let index = item.gradientIndex else { return nil }
            style.fill = .gradient(index)
        default:
            return nil
        }
        return style
    }

    private static func item(from a: AnnotatorAnnotation) -> Item {
        let c = a.colour.usingColorSpace(.sRGB) ?? a.colour
        return Item(
            kind: a.kind,
            rect: [a.rect.minX, a.rect.minY, a.rect.width, a.rect.height],
            start: [a.start.x, a.start.y],
            end: [a.end.x, a.end.y],
            points: a.points.map { [$0.x, $0.y] },
            colour: [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent],
            lineWidth: a.lineWidth,
            string: a.text?.string,
            textSize: a.textSize,
            textStyle: a.textStyle.rawValue,
            number: a.number,
            redactStyle: a.redactStyle.rawValue,
            arrowStyle: a.arrowStyle.rawValue)
    }

    private static func annotation(from item: Item) -> AnnotatorAnnotation {
        var a = AnnotatorAnnotation(kind: item.kind)
        if item.rect.count == 4 {
            a.rect = CGRect(x: item.rect[0], y: item.rect[1], width: item.rect[2], height: item.rect[3])
        }
        if item.start.count == 2 { a.start = CGPoint(x: item.start[0], y: item.start[1]) }
        if item.end.count == 2 { a.end = CGPoint(x: item.end[0], y: item.end[1]) }
        a.points = item.points.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        if item.colour.count == 4 {
            a.colour = NSColor(
                srgbRed: item.colour[0], green: item.colour[1],
                blue: item.colour[2], alpha: item.colour[3])
        }
        a.lineWidth = item.lineWidth
        a.textSize = item.textSize
        a.textStyle = AnnotatorTextStyle(rawValue: item.textStyle) ?? .standard
        a.number = item.number
        a.redactStyle = AnnotatorRedactStyle(rawValue: item.redactStyle) ?? .pixelate
        a.arrowStyle = AnnotatorArrowStyle(rawValue: item.arrowStyle) ?? .straight
        if let string = item.string {
            a.text = AnnotatorRender.attributed(
                string, size: a.textSize, colour: a.colour, style: a.textStyle)
        }
        return a
    }
}
