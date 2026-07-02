import AppKit

// Plain-swiftc top-level code is nonisolated; the whole boot happens on the
// main actor (run() never returns, so the delegate stays alive).
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
