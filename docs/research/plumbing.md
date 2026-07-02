# Sentry Capture — menu-bar app plumbing cheat-sheet
Target: macOS 15+, built with plain `swiftc` (Swift 6.3.2), verified on macOS 26.5 (Darwin 25.5). **VERIFIED-LOCAL** = compiled/ran on this exact setup; **VERIFIED-WEB** = confirmed against docs/reports; **UNVERIFIED** = flagged.

---

## 1. Global hotkeys via Carbon `RegisterEventHotKey` — no Accessibility permission

**VERIFIED-LOCAL**: the code below compiles with `swiftc -framework Carbon -framework AppKit` and `InstallEventHandler` / `RegisterEventHotKey` / `UnregisterEventHotKey` / re-register-at-runtime all return `noErr` (0) on macOS 26.5. **VERIFIED-WEB**: Carbon hotkeys still work on Tahoe (macOS 26) and are registered at the system level — no Accessibility checkbox, and they fire even over full-screen apps. What I could NOT verify locally is the callback *firing* (synthesising a keypress via `CGEvent.post` is itself TCC-gated and got silently dropped) — but real-hardware delivery on Tahoe is confirmed by the ecosystem (sindresorhus/KeyboardShortcuts, etc.) and web reports. One known OS bug: hotkeys whose *only* modifiers are Option or Option+Shift are broken since macOS 15 (FB15168205) — steer users to combos including Cmd/Ctrl/Shift.

```swift
import AppKit
import Carbon.HIToolbox   // link: -framework Carbon

final class HotKeyCentre {
    typealias Handler = () -> Void
    static let shared = HotKeyCentre()

    private var entries: [UInt32: (ref: EventHotKeyRef, handler: Handler)] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x53434150 // 'SCAP' fourCharCode — routes cookies back to us

    private init() {}

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Closure must be non-capturing (C convention); route self through userData.
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard err == noErr else { return err }
            let centre = Unmanaged<HotKeyCentre>.fromOpaque(userData).takeUnretainedValue()
            centre.entries[hkID.id]?.handler()   // fires on the main thread
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    /// keyCode is a Carbon virtual keycode (kVK_*) — same space as NSEvent.keyCode (UInt16).
    @discardableResult
    func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags,
                  handler: @escaping Handler) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode,
                                         carbonModifiers(from: modifiers),
                                         EventHotKeyID(signature: signature, id: id),
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }  // -9878 = combo already taken
        entries[id] = (ref, handler)
        return id
    }

    func unregister(_ id: UInt32) {
        guard let e = entries.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(e.ref)
    }
}

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mods: UInt32 = 0
    if flags.contains(.command) { mods |= UInt32(cmdKey) }     // 0x0100
    if flags.contains(.option)  { mods |= UInt32(optionKey) }  // 0x0800
    if flags.contains(.shift)   { mods |= UInt32(shiftKey) }   // 0x0200
    if flags.contains(.control) { mods |= UInt32(controlKey) } // 0x1000
    return mods
}
```

Key facts:
- Exact signature: `RegisterEventHotKey(_ inHotKeyCode: UInt32, _ inHotKeyModifiers: UInt32, _ inHotKeyID: EventHotKeyID, _ inTarget: EventTargetRef!, _ inOptions: OptionBits, _ outRef: UnsafeMutablePointer<EventHotKeyRef?>!) -> OSStatus`. Pass `0` for options.
- `GetEventParameter`'s buffer-size param is `ByteCount` = `Int` in Swift — `MemoryLayout<EventHotKeyID>.size` drops straight in (compile-verified).
- User-configurable shortcuts = just `unregister(old)` then `register(new)` — verified working at runtime.
- Key-up: also install `kEventHotKeyReleased` in the `EventTypeSpec` list if needed (pass 2 specs, `inNumTypes: 2`).
- Useful keycodes (`Carbon.HIToolbox`, compile-verified): `kVK_ANSI_3 = 0x14`, `kVK_ANSI_4 = 0x15`, `kVK_ANSI_5 = 0x17`, `kVK_Space = 0x31`, `kVK_Escape = 0x35`. Persist as `keyCode: UInt16` + `NSEvent.ModifierFlags.rawValue: UInt` in UserDefaults.
- Registering a combo the OS/another app owns returns `eventHotKeyExistsErr` (-9878) — surface that in the recorder UI.

### "Record shortcut" field — local NSEvent monitor (no permissions; app is focused)
**VERIFIED-LOCAL** (type-checked). While recording, `unregister()` your own global hotkeys first — a registered Carbon hotkey swallows the keypress system-wide before the local monitor sees it.

```swift
final class ShortcutRecorder {
    private var monitor: Any?
    var onCapture: ((UInt16, NSEvent.ModifierFlags) -> Void)?

    func begin() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if event.keyCode == 53, mods.isEmpty { self.end(); return nil }  // Esc cancels
            self.onCapture?(event.keyCode, mods)   // same keycode space as kVK_*
            self.end()
            return nil                             // swallow — don't beep/insert
        }
    }
    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
```
Optionally also watch `.flagsChanged` to live-preview held modifiers. To render the key name use `event.charactersIgnoringModifiers`; full layout-aware naming needs `UCKeyTranslate` (rabbit hole — skip initially).

---

## 2. LSUIElement menu-bar app assembled by hand

**Info.plist** (minimum viable; `CFBundleIdentifier` is the identity anchor for TCC + SMAppService — never change it once granted):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>SentryCapture</string>
    <key>CFBundleIdentifier</key><string>com.bisho.sentrycapture</string>
    <key>CFBundleName</key><string>Sentry Capture</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
```
`LSUIElement=true` → no Dock icon, no menu bar, launches with `.accessory` activation policy. No `PkgInfo` file needed. Screen Recording has **no** usage-description plist key — the TCC prompt is automatic on first capture attempt. (Mic capture, if you add it for recordings, needs `NSMicrophoneUsageDescription`.)

**Bundle layout + build script** (structure verified; the compile flags are exactly what I used locally):
```bash
APP=build/SentryCapture.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc Sources/*.swift -o "$APP/Contents/MacOS/SentryCapture" \
    -framework AppKit -framework Carbon -framework ServiceManagement \
    -framework UniformTypeIdentifiers -framework AudioToolbox
cp Info.plist "$APP/Contents/Info.plist"
# signing: see §4
```

**main.swift** (no @main attribute needed in a file literally named main.swift):
```swift
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

**Status item + menu** (VERIFIED-LOCAL type-check; keep a strong ref to the status item or it vanishes):
```swift
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder",
                                           accessibilityDescription: "Sentry Capture")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Capture Area", action: #selector(capture), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showPrefs), keyEquivalent: ","))
        statusItem.menu = menu   // assigning .menu = left-click always opens menu
    }
}
```

**Showing a normal window (prefs/annotator) from an accessory app — the dance:**
```swift
@objc func showPrefs() {
    previousApp = NSWorkspace.shared.frontmostApplication  // capture BEFORE stealing focus
    NSApp.setActivationPolicy(.regular)   // optional: Dock icon + main menu while window open
    NSApp.activate()                      // macOS 14+ cooperative activation
    prefsWindow.makeKeyAndOrderFront(nil)
}
// NSWindowDelegate — return focus when the window closes:
func windowWillClose(_ n: Notification) {
    NSApp.setActivationPolicy(.accessory)
    if let previousApp {
        NSApp.yieldActivation(to: previousApp)  // macOS 14+: consents to handing activation over
        previousApp.activate()
    }
}
```
- `NSApp.activate(ignoringOtherApps:)` is **deprecated since macOS 14**; plain `NSApp.activate()` + `yieldActivation(to:)` compile with zero deprecation warnings on the 26 SDK (VERIFIED-LOCAL). `activate()` succeeds here because the user just clicked your status item (recent user interaction ⇒ activation granted).
- If you skip `setActivationPolicy(.regular)`, the window still shows but there's no main menu → no Cmd+C/Cmd+W in your prefs window. `.regular` is worth it for the annotator.
- Known older gotcha (UNVERIFIED whether still needed on 26): after `.accessory → .regular` the main menu occasionally doesn't paint until the app re-activates; the classic workaround is set policy → `activate()` → `makeKeyAndOrderFront` in that exact order, and if it still misbehaves, briefly activate Finder then re-activate self.

---

## 3. SMAppService launch-at-login (macOS 13+, `import ServiceManagement`)

**VERIFIED-LOCAL** (type-check) + **VERIFIED-WEB** (behaviour):
```swift
try SMAppService.mainApp.register()      // throws on failure
try SMAppService.mainApp.unregister()
let s: SMAppService.Status = SMAppService.mainApp.status
// .notRegistered / .enabled / .requiresApproval / .notFound
SMAppService.openSystemSettingsLoginItems()   // deep-link to the pane
```
- Works for non-App-Store apps; no daemon/agent plumbing needed for the main app.
- **What the user sees**: a one-time system notification that a login item was added, and the app listed in **System Settings → General → Login Items & Extensions → "Open at Login"**. The user can toggle it off there — so never cache the state; re-read `.status` every time your prefs UI appears (e.g. on window focus).
- `.requiresApproval` = user disabled it in System Settings; show "enable in System Settings" + `openSystemSettingsLoginItems()`.
- Path stability: registration ties to the app at its current path — keep the app at a fixed location (`~/Applications/Sentry Capture.app`) and re-`register()` on launch if `.status != .enabled` and the user's pref says on. A swiftc-built app never downloaded has no quarantine flag, so no Gatekeeper app-translocation randomised paths.
- **UNVERIFIED**: whether `register()` succeeds for a strictly **ad-hoc**-signed app (no explicit reports either way). Moot in practice — sign with an Apple Development identity anyway (§4), which is a proper identity and definitely fine.

---

## 4. TCC Screen Recording stability across rebuilds

**VERIFIED-WEB** (TN3127 + multiple dev-forum reports):
- **Ad-hoc (`codesign --sign -`) breaks the grant on every rebuild.** TCC stores the app's *designated requirement*; an ad-hoc signature's DR degenerates to `cdhash H"…"`, which changes with every compile → new identity → grant invalid → re-prompt (Screen Recording often shows as still-toggled in System Settings but *doesn't work* until removed and re-added — worst case UX).
- **An "Apple Development" identity fixes it.** DR becomes bundle-ID + team anchored (stable across rebuilds as long as bundle ID and cert don't change) → TCC keeps the grant build after build. Any free Apple ID gets you an Apple Development cert (Xcode → Settings → Accounts → Manage Certificates; the cert lands in the login keychain and plain `codesign` can use it — no Xcode project needed).
- List identities: `security find-identity -v -p codesigning` — output lines look like `1) ABCDEF01… "Apple Development: Name (TEAMID)"`, footer `N valid identities found`. (VERIFIED-LOCAL: this machine currently prints `0 valid identities found` — a cert must be created before the stable-TCC path works here.)

Build-script selection with ad-hoc fallback:
```bash
IDENTITY=$(security find-identity -v -p codesigning \
           | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"   # falls back to ad-hoc "-"
```
- Hardened runtime (`--options runtime`) not needed for local dev or TCC; only for notarisation later.
- Dev reset between identity experiments: `tccutil reset ScreenCapture com.bisho.sentrycapture`.
- **The macOS 15+ nag is separate and unavoidable**: since Sequoia, screen-capture apps get a periodic "continue to allow / Allow For One Month" re-approval prompt (weekly in 15.0, roughly monthly since 15.1, plus after reboot/logout in early builds). Not caused by your signing; only `SCContentSharingPicker` flows bypass it, which doesn't fit hotkey-driven capture. (An MDM-gated `com.apple.developer.persistent-content-capture` entitlement exists for remote-desktop apps — not obtainable for this project; UNVERIFIED details.)

---

## 5. Drag-out with NSFilePromiseProvider (floating thumbnail → Finder/Slack/browser)

**VERIFIED-LOCAL** (all signatures type-check on the 26 SDK). Simplest robust shape: the PNG is already saved on disk (you save it anyway), so the promise is just a file copy.

```swift
import AppKit
import UniformTypeIdentifiers

final class ThumbnailView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var savedFileURL: URL!   // the capture, already written to disk
    var image: NSImage!

    private let promiseQueue: OperationQueue = {
        let q = OperationQueue(); q.qualityOfService = .userInitiated; return q
    }()

    override func mouseDragged(with event: NSEvent) {
        let provider = ImagePromiseProvider(fileType: UTType.png.identifier, delegate: self)
        provider.snapshotImage = image
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: image)   // drag image = the thumbnail itself
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } // drag from unfocused panel

    // MARK: NSDraggingSource
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    // MARK: NSFilePromiseProviderDelegate (exact selector names)
    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        savedFileURL.lastPathComponent           // e.g. "Capture 2026-07-02 at 10.30.00.png"
    }
    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do { try FileManager.default.copyItem(at: savedFileURL, to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
    func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue { promiseQueue }
}
```

Finder/Slack/Chrome all consume file promises. To *also* serve raw PNG data on the same drag item (helps web `<input type=file>`-less drop targets and image-pasteboard consumers), subclass the provider — this is Apple's own sample pattern:

```swift
final class ImagePromiseProvider: NSFilePromiseProvider {
    var snapshotImage: NSImage?
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png]
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .png ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .png {
            guard let tiff = snapshotImage?.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }
        return super.pasteboardPropertyList(forType: type)
    }
}
```
Gotchas: never block the main thread in `writePromiseTo` (hence the dedicated `OperationQueue`); one provider per dragging item (multi-item drags = multiple providers); `fileNameForType` collisions in the destination folder are auto-uniqued by the receiver, don't handle that yourself.

---

## 6. Non-activating floating panels (NSPanel)

**VERIFIED-LOCAL**: all flags/levels below type-check; level raw values printed on macOS 26.5: `.floating`=3 · `.mainMenu`=24 · `.statusBar`=25 · `.popUpMenu`=101 · `.screenSaver`=1000 · `CGShieldingWindowLevel()`=2147483628 · `CGWindowLevelForKey(.maximumWindow)`=2147483631.

```swift
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }   // borderless windows refuse key by default
    override var canBecomeMain: Bool { false }
}
```

**(a) Selection overlay — must cover menu bar + everything** (one panel **per NSScreen**, sized to `screen.frame`):
```swift
let panel = KeyablePanel(contentRect: screen.frame,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
panel.level = .screenSaver        // 1000 ≫ menu bar (24) and status items (25)
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
panel.backgroundColor = .clear
panel.isOpaque = false
panel.hasShadow = false
panel.isFloatingPanel = true
panel.hidesOnDeactivate = false   // critical: default panel behaviour hides on deactivate
panel.animationBehavior = .none   // no genie-in when ordering front
panel.acceptsMouseMovedEvents = true
panel.makeKeyAndOrderFront(nil)   // key (via override) so Esc/keyDown reach you — app still not activated
```
`.screenSaver` is the conventional choice (CleanShot-class apps). Going higher (`CGShieldingWindowLevel()`) also sits above the Cmd-Tab switcher and screenshots-of-screenshots — usually undesirable. Handle Esc in `keyDown` or `override func cancelOperation(_:)`.

**(b) Post-capture floating thumbnail — over full-screen apps, never steals focus:**
```swift
panel.level = .statusBar          // 25: above normal + fullscreen content, below your overlay
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.becomesKeyOnlyIfNeeded = true   // clicks/drags work without making it key
panel.orderFrontRegardless()          // show WITHOUT activating the app
```
`.fullScreenAuxiliary` is what actually lets it appear over another app's full-screen Space; level alone doesn't.

**(c) Pinned screenshots:**
```swift
panel.level = .floating           // 3: above normal windows, below menus/overlays
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.isMovableByWindowBackground = true
// optional click-through mode toggle:
panel.ignoresMouseEvents = true   // ALL events pass through; flip back to interact
```

Nuances:
- `.nonactivatingPanel` is only valid on `NSPanel` (not NSWindow) — clicking never activates your app, so the frontmost app keeps focus while the user drags your thumbnail. Exactly the CleanShot behaviour.
- `ignoresMouseEvents = true` is all-or-nothing per window (hover included). For partial click-through, keep it `false` and override `hitTest` in the content view to return `nil` for pass-through regions — note that returns clicks to *your other windows* only; genuine pass-through to other apps needs `ignoresMouseEvents`.
- `orderFrontRegardless()` vs `makeKeyAndOrderFront(nil)`: the former never takes key/activation (thumbnail); the latter + `canBecomeKey` gives you keyboard without app activation (selection overlay, because `.nonactivatingPanel`).
- Behaviour claims for (a)/(b)/(c) over full-screen Spaces are standard practice but were not visually exercised in this session — treat as VERIFIED-WEB/convention, smoke-test once wired.

---

## 7. Screenshot sound

**VERIFIED-LOCAL on macOS 26.5**: the system capture sounds still exist at
`/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif` (the classic screenshot "camera" sound) and `.../system/Shutter.aif`. `NSSound(contentsOf:byReference:)` loads and plays it (returned `true`), and `AudioServicesCreateSystemSoundID` on it returns 0. `/System/Library/Sounds/` contains only the 14 alert sounds (Basso…Tink) — no capture sound there, so `NSSound(named: "Grab")` does NOT work.

```swift
// Option A — NSSound (simplest; verified playing):
let grabURL = URL(fileURLWithPath:
  "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif")
NSSound(contentsOf: grabURL, byReference: true)?.play()

// Option B — AudioToolbox (lower latency, fire-and-forget; link -framework AudioToolbox):
var captureSound: SystemSoundID = 0
AudioServicesCreateSystemSoundID(grabURL as CFURL, &captureSound)   // once, at startup
AudioServicesPlaySystemSound(captureSound)                          // per capture
```

**Recommendation: ship your own copy.** That CoreAudio.component path is private/undocumented and has moved before — copy a short AIFF into `Contents/Resources/CaptureDone.aiff` and load it by name (searches the app bundle first, then `~/Library/Sounds`, `/Library/Sounds`, `/System/Library/Sounds`):
```swift
NSSound(named: "CaptureDone")?.play()
```
Keep a strong reference (or a cached `SystemSoundID`) if you notice playback cut off — NSSound stops if deallocated mid-play. Also respect a "play sound" preference; CleanShot does.

---

## Verification appendix
- Hotkey register/unregister/re-register: ran on macOS 26.5, all `OSStatus == 0`, swiftc 6.3.2, `-framework Carbon` — file at `/private/tmp/claude-501/-Users-bisho-Desktop-side-projects-sentry/4b394902-3923-4d1b-8db8-054a5c173a05/scratchpad/hotkey_test.swift`.
- Every other snippet: `swiftc -typecheck` clean (zero warnings) against the macOS 26 SDK — `.../scratchpad/compile_check.swift`.
- Window levels + sound playback: ran `.../scratchpad/levels.swift`.
- UNVERIFIED items: Carbon callback delivery (registration verified, delivery ecosystem-confirmed only); SMAppService under strict ad-hoc signing; menu-bar-paint workaround still needed on 26; persistent-content-capture entitlement details.

Sources: [Apple SMAppService docs](https://developer.apple.com/documentation/servicemanagement/smappservice), [TN3127 Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), [TCC across rebuilds — Apple dev forums](https://developer.apple.com/forums/thread/730043), [Launch-at-login UX writeup](https://nilcoalescing.com/blog/LaunchAtLoginSetting/), [SMAppService quick notes (theevilbit)](https://theevilbit.github.io/posts/smappservice/), [Tahoe hotkey/event-synthesis notes](https://www.nick-liu.com/posts/tahoe-hotkey-dead-end/), [Option-modifier hotkey bug FB15168205](https://github.com/feedback-assistant/reports/issues/552), [Sequoia screen-recording nag — TidBITS](https://tidbits.com/2024/09/23/how-to-avoid-sequoias-repetitive-screen-recording-permissions-prompts/), [AppleInsider on weekly prompts](https://appleinsider.com/articles/24/08/07/users-have-to-confirm-screen-recording-permission-every-week-in-macos-sequoia), [Daring Fireball on the nag](https://daringfireball.net/linked/2024/08/07/macos-15-sequoia-weekly-permission-prompts).