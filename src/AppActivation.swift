import AppKit

/// An LSUIElement app has no Dock icon or main menu; windows that want real
/// focus (annotator, preferences) must temporarily flip the activation
/// policy. Refcounted so multiple windows don't fight, and focus returns to
/// whatever app the user was in once the last window closes.
@MainActor
enum AppActivation {
    private static var count = 0
    private static var previousApp: NSRunningApplication?

    static func acquire() {
        count += 1
        guard count == 1 else {
            NSApp.activate()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func release() {
        count = max(0, count - 1)
        guard count == 0 else { return }
        NSApp.setActivationPolicy(.accessory)
        if let previousApp {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
        previousApp = nil
    }
}
