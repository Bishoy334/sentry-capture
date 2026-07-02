import AppKit
import Carbon.HIToolbox

/// The pixel colour picker (and its two-click contrast-checker mode). Freezes
/// the screen, magnifies around the cursor, samples the frozen frame — no dim
/// layer anywhere, because dimming would falsify the sampled colours.
@MainActor
final class ColourPickerController {
    static let shared = ColourPickerController()

    private init() {}

    private(set) var isActive = false
    private var contrastMode = false
    private var firstColour: NSColor?
    private var panels: [NSPanel] = []
    private var views: [ColourPickerView] = []
    private var frozen: [CGDirectDisplayID: StillCapture] = [:]
    fileprivate var frozenImages: [CGDirectDisplayID: NSImage] = [:]

    fileprivate var hintText: String {
        if contrastMode {
            return firstColour == nil
                ? "Pick the first colour — Esc cancels"
                : "Pick the second colour — Esc cancels"
        }
        return "Click to copy hex — Option-click for OKLCH — Esc cancels"
    }

    func begin(contrastMode: Bool = false) {
        guard !isActive else { return }
        isActive = true
        self.contrastMode = contrastMode
        firstColour = nil
        Task { @MainActor in
            do {
                let content = try await CaptureEngine.shared.shareableContent()
                for display in content.displays {
                    guard let still = try? await CaptureEngine.shared.captureDisplay(display),
                          self.isActive else { continue }
                    frozen[display.displayID] = still
                    frozenImages[display.displayID] = NSImage(
                        cgImage: still.image, size: still.pointSize)
                }
                guard self.isActive else { return }
                self.presentOverlay()
            } catch {
                self.isActive = false
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
            }
        }
    }

    private func presentOverlay() {
        for screen in NSScreen.screens {
            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.acceptsMouseMovedEvents = true
            let view = ColourPickerView(screen: screen, controller: self)
            panel.contentView = view
            panels.append(panel)
            views.append(view)
        }
        NSCursor.crosshair.push()
        let mouse = NSEvent.mouseLocation
        let keyIndex = NSScreen.screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        for (i, panel) in panels.enumerated() where i != keyIndex {
            panel.orderFrontRegardless()
        }
        (panels[keyIndex] as? NSWindow)?.makeKeyAndOrderFront(nil)
        for (i, panel) in panels.enumerated() {
            panel.makeFirstResponder(views[i])
        }
    }

    fileprivate func finish() {
        guard isActive else { return }
        isActive = false
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        frozen.removeAll()
        frozenImages.removeAll()
        firstColour = nil
        NSCursor.pop()
    }

    // MARK: Sampling

    fileprivate func colour(at cgPoint: CGPoint, displayID: CGDirectDisplayID) -> NSColor? {
        guard let still = frozen[displayID],
              let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            return nil
        }
        let local = CGPoint(
            x: cgPoint.x - Coords.cgRect(fromAppKit: screen.frame).minX,
            y: cgPoint.y - Coords.cgRect(fromAppKit: screen.frame).minY)
        let px = Int(local.x * still.scale)
        let py = Int(local.y * still.scale)
        guard px >= 0, py >= 0, px < still.image.width, py < still.image.height,
              let crop = still.image.cropping(to: CGRect(x: px, y: py, width: 1, height: 1))
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(
            srgbRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1)
    }

    fileprivate func picked(_ colour: NSColor, option: Bool) {
        if contrastMode {
            if let first = firstColour {
                let ratio = ColourMaths.contrastRatio(first, colour)
                let summary = String(
                    format: "%.2f:1 — AA %@, AAA %@",
                    ratio,
                    ratio >= 4.5 ? "pass" : "fail",
                    ratio >= 7 ? "pass" : "fail")
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("Contrast \(summary)", forType: .string)
                Toast.show("Contrast \(summary)", symbol: "circle.lefthalf.filled", duration: 3)
                finish()
            } else {
                firstColour = colour
                for view in views { view.invalidateHintArea() }
            }
            return
        }
        let text = option ? ColourMaths.oklchString(colour) : ColourMaths.hexString(colour)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Toast.show("\(text) copied", symbol: "eyedropper")
        finish()
    }
}

// MARK: - Colour maths

enum ColourMaths {
    static func hexString(_ colour: NSColor) -> String {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        return String(
            format: "#%02X%02X%02X",
            Int(round(c.redComponent * 255)),
            Int(round(c.greenComponent * 255)),
            Int(round(c.blueComponent * 255)))
    }

    private static func linear(_ v: CGFloat) -> Double {
        let v = Double(v)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// WCAG 2.x relative-luminance contrast ratio.
    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ c: NSColor) -> Double {
            let s = c.usingColorSpace(.sRGB) ?? c
            return 0.2126 * linear(s.redComponent)
                + 0.7152 * linear(s.greenComponent)
                + 0.0722 * linear(s.blueComponent)
        }
        let l1 = luminance(a)
        let l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// sRGB -> OKLab -> OKLCH (Björn Ottosson's reference transform).
    static func oklchString(_ colour: NSColor) -> String {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        let r = linear(c.redComponent)
        let g = linear(c.greenComponent)
        let b = linear(c.blueComponent)

        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

        let lc = cbrt(l), mc = cbrt(m), sc = cbrt(s)

        let okL = 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc
        let okA = 1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc
        let okB = 0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc

        let chroma = sqrt(okA * okA + okB * okB)
        var hue = atan2(okB, okA) * 180 / .pi
        if hue < 0 { hue += 360 }
        // Near-achromatic colours have meaningless hue.
        if chroma < 0.0005 {
            return String(format: "oklch(%.1f%% 0 0)", okL * 100)
        }
        return String(format: "oklch(%.1f%% %.3f %.1f)", okL * 100, chroma, hue)
    }
}

// MARK: - View

@MainActor
private final class ColourPickerView: NSView {
    private unowned let controller: ColourPickerController
    private let screenFrameCG: CGRect
    private let displayID: CGDirectDisplayID
    private let topInset: CGFloat
    private var mouseLocal: NSPoint = .zero

    init(screen: NSScreen, controller: ColourPickerController) {
        self.controller = controller
        self.screenFrameCG = Coords.cgRect(fromAppKit: screen.frame)
        self.displayID = screen.displayID
        self.topInset = screen.frame.maxY - screen.visibleFrame.maxY
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func invalidateHintArea() {
        setNeedsDisplay(NSRect(x: bounds.midX - 320, y: 0, width: 640, height: topInset + 64))
    }

    private func localPoint(_ event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func cgPoint(_ local: NSPoint) -> CGPoint {
        CGPoint(x: local.x + screenFrameCG.minX, y: local.y + screenFrameCG.minY)
    }

    override func mouseMoved(with event: NSEvent) {
        let old = mouseLocal
        mouseLocal = localPoint(event)
        for p in [old, mouseLocal] {
            setNeedsDisplay(NSRect(x: p.x - 170, y: p.y - 170, width: 340, height: 340))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = localPoint(event)
        guard let colour = controller.colour(at: cgPoint(p), displayID: displayID) else { return }
        controller.picked(colour, option: event.modifierFlags.contains(.option))
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            controller.finish()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Frozen frame, undimmed — colour fidelity is the whole point.
        controller.frozenImages[displayID]?.draw(
            in: bounds, from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: 1)])

        guard bounds.insetBy(dx: -1, dy: -1).contains(mouseLocal) else { return }
        drawLoupe(at: mouseLocal)
        drawHint()
    }

    private func drawLoupe(at p: NSPoint) {
        guard let colour = controller.colour(at: cgPoint(p), displayID: displayID),
              let image = controller.frozenImages[displayID] else { return }
        let size: CGFloat = 130
        let magnification: CGFloat = 12
        var origin = NSPoint(x: p.x + 24, y: p.y + 24)
        if origin.x + size > bounds.maxX - 8 { origin.x = p.x - size - 24 }
        if origin.y + size + 48 > bounds.maxY - 8 { origin.y = p.y - size - 48 }
        let rect = NSRect(x: origin.x, y: origin.y, width: size, height: size)

        let sourceSide = size / magnification
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: rect).addClip()
        image.draw(
            in: rect,
            from: NSRect(
                x: p.x - sourceSide / 2,
                y: image.size.height - p.y - sourceSide / 2,
                width: sourceSide, height: sourceSide),
            operation: .sourceOver, fraction: 1, respectFlipped: false,
            hints: [.interpolation: NSNumber(value: 1)])
        NSGraphicsContext.restoreGraphicsState()

        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        colour.setStroke()
        ring.stroke()
        let outer = NSBezierPath(ovalIn: rect)
        outer.lineWidth = 1
        NSColor.white.withAlphaComponent(0.8).setStroke()
        outer.stroke()

        // Centre pixel marker.
        let cell = size / (sourceSide * (window?.backingScaleFactor ?? 2))
        let tick = NSRect(
            x: rect.midX - cell / 2, y: rect.midY - cell / 2, width: cell, height: cell)
        NSColor.white.setStroke()
        NSBezierPath(rect: tick).stroke()

        // Swatch + hex readout under the loupe.
        let hex = ColourMaths.hexString(colour)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (hex as NSString).size(withAttributes: attrs)
        let pillRect = NSRect(
            x: rect.midX - (textSize.width + 34) / 2, y: rect.maxY + 6,
            width: textSize.width + 34, height: textSize.height + 10)
        let pill = NSBezierPath(
            roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
        NSColor.black.withAlphaComponent(0.7).setFill()
        pill.fill()
        let swatch = NSRect(
            x: pillRect.minX + 7, y: pillRect.midY - 6, width: 12, height: 12)
        colour.setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).stroke()
        (hex as NSString).draw(
            at: NSPoint(x: swatch.maxX + 6, y: pillRect.midY - textSize.height / 2),
            withAttributes: attrs)
    }

    private func drawHint() {
        let text = controller.hintText
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let rect = NSRect(
            x: (bounds.width - textSize.width - 28) / 2,
            y: topInset + 16,
            width: textSize.width + 28,
            height: textSize.height + 12)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        pill.fill()
        (text as NSString).draw(
            at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
            withAttributes: attrs)
    }
}
