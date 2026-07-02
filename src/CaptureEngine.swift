import AppKit
import CoreVideo
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noPermission
    case displayNotFound
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPermission: return "Screen Recording permission is required."
        case .displayNotFound: return "Could not find the display to capture."
        case .captureFailed(let why): return "Capture failed: \(why)"
        }
    }
}

/// All still-image capture goes through here. Rects in/out are global CG
/// top-left-origin points (see Coords in Types.swift).
final class CaptureEngine {
    static let shared = CaptureEngine()

    private init() {}

    // MARK: Permission

    var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// CGRequestScreenCaptureAccess shows the system prompt only once per
    /// install; afterwards the user must flip the System Settings toggle and
    /// macOS requires a relaunch for the grant to take effect.
    @MainActor
    func requestPermission() {
        if CGRequestScreenCaptureAccess() { return }
        let alert = NSAlert()
        alert.messageText = "Sentry Capture needs Screen Recording access"
        alert.informativeText = "Enable Sentry Capture under System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch the app (macOS requires it)."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Shareable content

    func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch let error as NSError where error.domain == SCStreamErrorDomain
            && error.code == SCStreamError.Code.userDeclined.rawValue {
            throw CaptureError.noPermission
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }

    func display(containing rect: CGRect, in content: SCShareableContent) -> SCDisplay? {
        // Largest intersection wins; fall back to the display under the rect's origin.
        var best: (SCDisplay, CGFloat)?
        for display in content.displays {
            let overlap = display.frame.intersection(rect)
            guard !overlap.isNull, overlap.width * overlap.height > (best?.1 ?? 0) else { continue }
            best = (display, overlap.width * overlap.height)
        }
        return best?.0 ?? content.displays.first { $0.frame.contains(rect.origin) }
    }

    /// Windows belonging to us (selection overlays, QAO, pins, toasts) that
    /// must never appear inside a capture. sharingType = .none stopped
    /// working on macOS 15+, so filter-level exclusion is the only way.
    func ourWindows(in content: SCShareableContent) -> [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == pid }
    }

    // MARK: Stills

    /// Capture an arbitrary region. `rect` in global CG top-left points.
    func captureRect(_ rect: CGRect, source: StillSource = .area) async throws -> StillCapture {
        let content = try await shareableContent()
        guard let display = display(containing: rect, in: content) else {
            throw CaptureError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: ourWindows(in: content))
        let scale = CGFloat(filter.pointPixelScale)

        let config = stillConfig()
        // sourceRect is filter-content-local, in points.
        config.sourceRect = CGRect(
            x: rect.minX - display.frame.minX,
            y: rect.minY - display.frame.minY,
            width: rect.width,
            height: rect.height
        )
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())

        let image = try await screenshot(filter: filter, config: config)
        return StillCapture(image: image, scale: scale, source: source, screenRect: rect)
    }

    func captureDisplay(_ display: SCDisplay) async throws -> StillCapture {
        let content = try await shareableContent()
        let filter = SCContentFilter(display: display, excludingWindows: ourWindows(in: content))
        let scale = CGFloat(filter.pointPixelScale)

        let config = stillConfig()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())

        let image = try await screenshot(filter: filter, config: config)
        return StillCapture(image: image, scale: scale, source: .fullscreen, screenRect: display.frame)
    }

    /// Capture the display the mouse pointer is currently on.
    func captureActiveDisplay() async throws -> StillCapture {
        let content = try await shareableContent()
        let mouse = Coords.cgPoint(fromAppKit: NSEvent.mouseLocation)
        let display = content.displays.first { $0.frame.contains(mouse) } ?? content.displays.first
        guard let display else { throw CaptureError.displayNotFound }
        return try await captureDisplay(display)
    }

    func captureWindow(_ window: SCWindow) async throws -> StillCapture {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)

        let config = stillConfig()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        // Pixel-exact sizing only works shadow-free — the shadow margin isn't
        // reported by any API. Transparent rounded corners survive (BGRA).
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.scalesToFit = false

        let image = try await screenshot(filter: filter, config: config)
        return StillCapture(image: image, scale: scale, source: .window, screenRect: window.frame)
    }

    private func stillConfig() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.captureResolution = .best
        return config
    }

    private func screenshot(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }
}
