import Foundation

/// Disables/enables the built-in macOS screenshot keyboard shortcuts so Sentry
/// Capture can own ⌘⇧3/4/5 without the system double-firing. Mirrors what
/// CleanShot X does: flip the `enabled` flag on the relevant
/// AppleSymbolicHotKeys entries in com.apple.symbolichotkeys, then reload the
/// shortcut daemon so the change takes effect without a re-login.
enum SystemScreenshotShortcuts {
    /// AppleSymbolicHotKeys IDs for the screenshot family:
    /// 28/29 = whole screen (file / clipboard), 30/31 = selected area
    /// (file / clipboard), 184 = the ⌘⇧5 screenshot & recording bar.
    private static let ids = [28, 29, 30, 31, 184]
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString

    /// `enabled` true restores the macOS shortcuts; false disables them.
    static func setSystemEnabled(_ enabled: Bool) {
        let current = CFPreferencesCopyValue(
            key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
        var dict = current ?? [:]
        for id in ids {
            let k = String(id)
            var entry = (dict[k] as? [String: Any]) ?? [:]
            entry["enabled"] = enabled ? 1 : 0
            dict[k] = entry
        }
        CFPreferencesSetValue(
            key, dict as CFPropertyList, domain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        reloadHotkeyDaemon()
    }

    /// Push the plist change into the running WindowServer without a re-login.
    /// Best-effort — the plist write above is authoritative and survives a
    /// logout even if this reload no-ops on a given macOS build.
    private static func reloadHotkeyDaemon() {
        let tool = "/System/Library/PrivateFrameworks/SystemAdministration.framework"
            + "/Resources/activateSettings"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-u"]
        try? p.run()
    }
}
