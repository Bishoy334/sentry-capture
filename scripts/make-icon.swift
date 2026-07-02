// Generates assets/icon-1024.png — the master for AppIcon.icns.
// Run: swift scripts/make-icon.swift && bash scripts/make-icon.sh
import AppKit

let canvas: CGFloat = 1024

// SF Symbol drawn as a white glyph on its own layer first — drawing it
// straight onto the gradient would keep its template-black fill.
func whiteGlyph(_ name: String, points: CGFloat) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: points, weight: .medium)) else { return nil }
    let img = NSImage(size: base.size)
    img.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: base.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
    img.unlockFocus()
    return img
}

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// macOS icon grid: 824pt rounded rect centred in the 1024 canvas.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)

NSGraphicsContext.current?.saveGraphicsState()
platePath.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.17, alpha: 1),
    NSColor(calibratedRed: 0.14, green: 0.29, blue: 0.58, alpha: 1),
])?.draw(in: plate, angle: 90)
NSGraphicsContext.current?.restoreGraphicsState()

NSColor.white.withAlphaComponent(0.08).setStroke()
platePath.lineWidth = 4
platePath.stroke()

if let glyph = whiteGlyph("camera.viewfinder", points: 430) {
    let size = glyph.size
    glyph.draw(in: NSRect(
        x: (canvas - size.width) / 2, y: (canvas - size.height) / 2,
        width: size.width, height: size.height))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("render failed\n", stderr)
    exit(1)
}
let out = URL(fileURLWithPath: "assets/icon-1024.png")
try? FileManager.default.createDirectory(
    at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: out)
print("wrote \(out.path)")
