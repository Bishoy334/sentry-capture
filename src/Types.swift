import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

enum StillSource {
    case area, window, fullscreen, scrolling
}

/// What the capture was of — feeds the record manifest's `source` block so
/// downstream Sentry apps know which app/window a capture came from.
struct CaptureOrigin {
    var appBundleID: String?
    var appName: String?
    var windowTitle: String?
    var displayID: UInt32?

    /// The frontmost app at capture time — the best guess for area and
    /// fullscreen captures, where no specific window was picked.
    @MainActor
    static func frontmost(displayID: UInt32? = nil) -> CaptureOrigin {
        let app = NSWorkspace.shared.frontmostApplication
        return CaptureOrigin(
            appBundleID: app?.bundleIdentifier,
            appName: app?.localizedName,
            windowTitle: nil,
            displayID: displayID
        )
    }
}

/// A captured still image. `image` is at native pixel resolution; `scale` is
/// pixels-per-point (2 on retina), so point dimensions = pixel dimensions / scale.
struct StillCapture {
    let image: CGImage
    let scale: CGFloat
    let source: StillSource
    /// Where on screen the capture came from, in global CG top-left-origin points.
    /// nil for composites (scrolling capture) and annotator exports.
    let screenRect: CGRect?
    /// Capture-time provenance for the record manifest.
    var origin: CaptureOrigin? = nil
    /// The Sentry record this capture belongs to, once delivered — re-exports
    /// (annotator/QAO/pin saves) update that record instead of forking.
    var recordID: String? = nil

    var pointSize: NSSize {
        NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}

struct VideoCapture {
    let url: URL
    let isGIF: Bool
    var origin: CaptureOrigin? = nil
    var durationSeconds: Double? = nil
}

/// A capture after OutputRouter has applied the after-capture actions.
/// `fileURL` is set when it was saved to disk (QAO drag-out reuses the file).
struct DeliveredCapture {
    enum Payload {
        case still(StillCapture)
        case video(VideoCapture)
    }
    let payload: Payload
    var fileURL: URL?
    /// The Sentry record backing this capture — Send to… and re-editing key off it.
    var recordID: String?
}

/// Every rect that crosses a module boundary is in GLOBAL CoreGraphics
/// coordinates: origin at the top-left of the primary display, y growing
/// downward — the space ScreenCaptureKit, CGWindow and CGEvent use. AppKit
/// screen coordinates put the origin at the primary display's bottom-left with
/// y growing upward. The flip is about the primary screen's top edge and is
/// its own inverse.
enum Coords {
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func cgRect(fromAppKit r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }

    static func appKitRect(fromCG r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cgPoint(fromAppKit p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryScreenHeight - p.y)
    }

    static func appKitPoint(fromCG p: CGPoint) -> NSPoint {
        NSPoint(x: p.x, y: primaryScreenHeight - p.y)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

enum HotkeyAction: String, CaseIterable, Codable {
    case allInOne
    case captureArea
    case captureWindow
    case captureFullscreen
    case scrollingCapture
    case recordVideo
    case recordGIF
    case copyText
    case pinArea
    case timedCapture
    case colourPicker
    case measure
    case checkContrast

    var title: String {
        switch self {
        case .allInOne: return "All-in-One Capture"
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .captureFullscreen: return "Capture Fullscreen"
        case .scrollingCapture: return "Scrolling Capture"
        case .recordVideo: return "Record Video"
        case .recordGIF: return "Record GIF"
        case .copyText: return "Copy Text (OCR)"
        case .pinArea: return "Pin Area"
        case .timedCapture: return "Timed Area Capture"
        case .colourPicker: return "Colour Picker"
        case .measure: return "Measure"
        case .checkContrast: return "Check Contrast"
        }
    }

    var defaultHotkey: Hotkey? {
        // Option-Command family: clear of the system's Cmd-Shift-3/4/5, and
        // avoids the macOS 15+ bug where Option-only / Option-Shift-only
        // hotkeys never fire (FB15168205).
        switch self {
        case .allInOne: return Hotkey(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: optionCmd)
        case .copyText: return Hotkey(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: optionCmd)
        case .captureFullscreen: return Hotkey(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: optionCmd)
        case .captureArea: return Hotkey(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: optionCmd)
        case .captureWindow: return Hotkey(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: optionCmd)
        case .scrollingCapture: return Hotkey(keyCode: UInt32(kVK_ANSI_6), carbonModifiers: optionCmd)
        case .recordVideo: return Hotkey(keyCode: UInt32(kVK_ANSI_7), carbonModifiers: optionCmd)
        case .pinArea: return Hotkey(keyCode: UInt32(kVK_ANSI_8), carbonModifiers: optionCmd)
        case .colourPicker: return Hotkey(keyCode: UInt32(kVK_ANSI_9), carbonModifiers: optionCmd)
        case .measure: return Hotkey(keyCode: UInt32(kVK_ANSI_0), carbonModifiers: optionCmd)
        case .recordGIF, .timedCapture, .checkContrast: return nil
        }
    }
}

private let optionCmd = UInt32(optionKey | cmdKey)

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += Hotkey.keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: UInt32) -> String {
        if let name = keyNames[Int(keyCode)] { return name }
        return "key\(keyCode)"
    }

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_Tab: "⇥", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Grave: "`",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]
}
