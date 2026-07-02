# ScreenCaptureKit still-capture cheat-sheet (macOS 15+ target, swiftc, AppKit menu-bar app)

**Verification basis:** every declaration below was checked against the local MacOSX26.5 SDK headers (`ScreenCaptureKit.framework/Headers/*.h`, `CoreGraphics/CGWindow.h`) and **all Swift snippets typecheck with `swiftc -target arm64-apple-macos15.0`** on Swift 6.3.2. Items I could not verify (no Screen Recording TCC grant on the research machine, so no live captures) are marked **UNVERIFIED**. macOS-26-only APIs are marked; deployment target 15.0 means guard them with `#available`.

**Imports needed:** `import ScreenCaptureKit` (pulls in AppKit types), `import AppKit`, `import CoreVideo` (pixel formats), `import ImageIO` + `import UniformTypeIdentifiers` (file writing). Link happens automatically via auto-linking with swiftc; no extra `-framework` flags required beyond `-framework ScreenCaptureKit` if you disable autolink (normally not needed).

## Availability matrix (from SDK headers — authoritative)

| API | macOS |
|---|---|
| `SCShareableContent`, `SCContentFilter` (all 5 inits), `SCStreamConfiguration` core fields (`width/height/sourceRect/destinationRect/scalesToFit/pixelFormat/colorSpaceName/colorMatrix/showsCursor/backgroundColor/queueDepth`) | 12.3 |
| `SCScreenshotManager`, `.captureImage(contentFilter:configuration:)`, `.captureSampleBuffer(...)`; `SCContentFilter.pointPixelScale/.contentRect/.style`; `SCShareableContent.info(for:)`; config `ignoreShadowsDisplay/ignoreShadowsSingleWindow/captureResolution/capturesShadowsOnly/shouldBeOpaque/ignoreGlobalClipDisplay/ignoreGlobalClipSingleWindow/preservesAspectRatio` | 14.0 |
| `SCContentFilter.includeMenuBar`, config `includeChildWindows` | 14.2 |
| `SCShareableContent.currentProcess` (no-TCC, redacted) | 14.4 |
| `SCStreamConfiguration(preset:)`, `captureDynamicRange`, `showMouseClicks` | 15.0 |
| **`SCScreenshotManager.captureImage(in:)`**; `filter.includedDisplays/.includedApplications/.includedWindows` | **15.2** |
| `SCScreenshotConfiguration` / `SCScreenshotOutput` / `captureScreenshot(contentFilter:configuration:)` / `captureScreenshot(rect:configuration:)` (direct-to-file PNG/JPEG/HEIC, HDR) | **26.0** |
| `CGPreflightScreenCaptureAccess()`, `CGRequestScreenCaptureAccess()` | 10.15 |

---

## 1. SCShareableContent — enumeration + caching

```swift
// Everything (all spaces, incl. off-screen windows):
let content = try await SCShareableContent.current                    // async class property
// Picker-appropriate fetch (what you almost always want):
let content = try await SCShareableContent.excludingDesktopWindows(
    true,                       // drop Finder desktop/wallpaper/icon layer windows
    onScreenWindowsOnly: true)  // only currently visible windows
// Also exist: .excludingDesktopWindows(_:onScreenWindowsOnlyBelow: SCWindow)
//             .excludingDesktopWindows(_:onScreenWindowsOnlyAbove: SCWindow)
content.displays: [SCDisplay]   // .displayID: CGDirectDisplayID, .width/.height: Int (POINTS), .frame: CGRect (POINTS, CG global top-left space — == CGDisplayBounds)
content.windows:  [SCWindow]    // .windowID: CGWindowID, .frame: CGRect (POINTS, CG global space), .title: String?, .windowLayer: Int, .owningApplication: SCRunningApplication?, .isOnScreen, .isActive (13.1+)
content.applications: [SCRunningApplication] // .bundleIdentifier, .applicationName, .processID: pid_t
```

- **First call triggers the TCC prompt** if the app isn't authorised; when denied it throws `SCStreamError.Code.userDeclined` (-3801, domain `SCStreamErrorDomain`).
- The fetch is an XPC round trip — order tens-to-~hundreds of ms (approx.; don't call per mouse-move).

**Excluding our own overlay windows** — two mechanisms; use the filter, not `sharingType`:
```swift
// A) Match by PID (catches all our windows incl. panels):
let myPID = pid_t(ProcessInfo.processInfo.processIdentifier)
let myWindows = content.windows.filter { $0.owningApplication?.processID == myPID }
let filter = SCContentFilter(display: display, excludingWindows: myWindows)
// B) Match a specific NSWindow (must be on screen; call on MainActor):
let overlayID = CGWindowID(overlayWindow.windowNumber)   // windowNumber valid only after ordering on screen
let scOverlay = content.windows.first { $0.windowID == overlayID }
```
- **`NSWindow.sharingType = .none` is NOT reliable on macOS 15+**: on 15.x ScreenCaptureKit captures the composited framebuffer and ignores it (confirmed by tauri #14200 and Apple dev-forums thread 792152; it only affects legacy CG APIs). Don't build on it. For capture paths that take **no filter** (`captureImage(in:)`), either build a display filter + `sourceRect` instead (preferred), or hide the overlay (`orderOut(nil)`, wait ~1 frame, e.g. `try await Task.sleep(nanoseconds: 50_000_000)`) before capturing.

**Window-picker filtering heuristic** (standard practice): keep `w.windowLayer == 0` (0 = normal app windows; dock/menubar/overlays sit on other layers), `w.isOnScreen`, `w.frame.width > 50 && w.frame.height > 50`, `w.owningApplication?.processID != myPID`.

**Caching strategy:**
- **Displays:** cache; invalidate on `NSApplication.didChangeScreenParametersNotification` (fires on plug/unplug/resolution/arrangement change).
- **Windows:** never cache across user actions — frames/z-order stale instantly. Refetch when entering window-pick mode; while the picker is live, refetch on a throttle (~0.5–1 s) for hover-highlight.
- **Failure recovery:** a capture with a stale `SCWindow` (window closed) fails (`noCaptureSource` -3815 family) → refetch content and retry once.
- Fetch once at launch (post-permission) to warm the connection.

## 2. SCContentFilter variants — what each captures

```swift
SCContentFilter(desktopIndependentWindow: w)                     // one window, even if occluded / on another Space
SCContentFilter(display: d, excludingWindows: [SCWindow])        // whole display minus listed windows
SCContentFilter(display: d, including: [SCWindow])               // only these windows, composited at their on-screen positions
SCContentFilter(display: d, including: [SCRunningApplication], exceptingWindows: [SCWindow])
SCContentFilter(display: d, excludingApplications: [SCRunningApplication], exceptingWindows: [SCWindow])
```

| Variant | desktop wallpaper + dock | menu bar (`includeMenuBar`, 14.2+) | notes |
|---|---|---|---|
| `display:excludingWindows:` | **included** | default **true** | the ⌘⇧3-style capture; pass own windows to exclude |
| `display:including:` / `including:apps:` | excluded | default **false** | windows composited on transparent canvas sized to display (`backgroundColor` default clear) |
| `excludingApplications:exceptingWindows:` | **included** | default true (excluding-style) | "everything except app X" |
| `desktopIndependentWindow:` | n/a | no effect (header: property has no effect for this filter) | captures window contents even when occluded; **off-screen parts clipped by default** — set `ignoreGlobalClipSingleWindow = true` to capture the full window when partially off-screen |

Filter introspection (macOS 14+, key to pixel-perfect sizing):
```swift
filter.contentRect: CGRect     // size+location of filter content, POINTS (global, top-left-origin space)
filter.pointPixelScale: Float  // backing scale of the content (2.0 or 3.0 on retina, 1.0 otherwise)
filter.style: SCShareableContentStyle // .display / .window / .application
```

**Shadows:**
- Display-style filters: window shadows appear as on screen; `config.ignoreShadowsDisplay = true` removes them.
- Single-window filter: shadow is part of the composited content by default (`ignoreShadowsSingleWindow = false`), **but** `contentRect`/`SCWindow.frame` do NOT include the shadow margin and no public API reports it — so sizing output as `contentRect × pointPixelScale` while keeping the shadow does not produce a pixel-exact result (Apple dev-forums confirmed; the shadowed content gets fitted into your width/height). **UNVERIFIED empirically** (exact fit/crop behaviour).
- Practical recipes: (1) crisp capture: `ignoreShadowsSingleWindow = true` + exact sizing → pixel-perfect window with transparent rounded corners (BGRA alpha; leave `shouldBeOpaque = false`); composite your **own** shadow at export time — this is what screenshot tools actually do. (2) `capturesShadowsOnly = true` (14+) captures only the shadow layer if you want the genuine system shadow as a separate pass (same sizing caveat, UNVERIFIED).

## 3. SCScreenshotManager — exact signatures

All are **class** methods (`init` unavailable). ObjC completion-handler methods; Swift also gets `async` versions automatically:
```swift
// macOS 14.0+
class func captureImage(contentFilter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage
class func captureImage(contentFilter: SCContentFilter, configuration: SCStreamConfiguration,
                        completionHandler: ((CGImage?, (any Error)?) -> Void)?)
class func captureSampleBuffer(contentFilter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CMSampleBuffer
// macOS 15.2+  — rect in POINTS, GLOBAL display space (CG top-left origin), spans multiple displays
class func captureImage(in rect: CGRect) async throws -> CGImage
// macOS 26.0+ — see §8
class func captureScreenshot(contentFilter: SCContentFilter, configuration: SCScreenshotConfiguration) async throws -> SCScreenshotOutput
class func captureScreenshot(rect: CGRect, configuration: SCScreenshotConfiguration) async throws -> SCScreenshotOutput
```
`captureImage(in:)` takes **no configuration**: no window exclusion, cursor/scale behaviour not documented (**UNVERIFIED** — check `image.width` at runtime; prefer the filter+`sourceRect` path below, keep this as the cross-display-rect fallback).

## 4. SCStreamConfiguration fields that matter for stills

| Field | Type | Unit / default (from SDK header) | Avail |
|---|---|---|---|
| `width`, `height` | `Int` (`size_t`) | **PIXELS; defaults 1920×1080 — ALWAYS set both** or you get a scaled 1080p image | 12.3 |
| `sourceRect` | `CGRect` | **POINTS, local coordinate space of the filter content** (display filter → display-local top-left-origin; window filter → window-local). Unset = full content | 12.3 |
| `destinationRect` | `CGRect` | PIXELS within the output surface; unset = whole surface. Rarely needed for stills | 12.3 |
| `scalesToFit` | `Bool` | for window capture: `false` = only scales down, `true` = scales up and down | 12.3 |
| `preservesAspectRatio` | `Bool` | default `true` | 14.0 |
| `pixelFormat` | `OSType` | `'BGRA'` (default), `'l10r'`, `'420v'`, `'420f'`, `'xf44'`, `'RGhA'` (half-float, HDR). Stills → `kCVPixelFormatType_32BGRA` | 12.3 |
| `colorSpaceName` | `CFString` | default = display's colour space; set `CGColorSpace.sRGB` for compatibility or `CGColorSpace.displayP3` to match system screenshots on P3 Macs | 12.3 |
| `showsCursor` | `Bool` | default `true` — set `false` for stills unless user opts in | 12.3 |
| `captureResolution` | `SCCaptureResolutionType` `.automatic/.best/.nominal` | `.best` = native pixels, `.nominal` = 1 px/pt | 14.0 |
| `shouldBeOpaque` | `Bool` | `true` backs transparent areas with white | 14.0 |
| `ignoreShadowsDisplay` / `ignoreShadowsSingleWindow` | `Bool` | default `false` (shadows in) | 14.0 |
| `ignoreGlobalClipDisplay` / `ignoreGlobalClipSingleWindow` | `Bool` | `true` = don't clip content beyond display edge | 14.0 |
| `includeChildWindows` | `Bool` | default `true`; display-bound filters only | 14.2 |
| `backgroundColor` | `CGColorRef` | default clear | 12.3 |

HDR stills (15.0+): `SCStreamConfiguration(preset: .captureHDRScreenshotLocalDisplay)` (or `Canonical`), pairs with `captureDynamicRange` — Apple-suggested pixelFormat/colourSpace bundle.

## 5. Pixel-perfect retina recipes (typechecked)

**(a) Full display** — points × scale = exact framebuffer pixels (works for scaled retina modes too):
```swift
func captureDisplay(display: SCDisplay, exclude: [SCWindow]) async throws -> CGImage {
    let filter = SCContentFilter(display: display, excludingWindows: exclude)
    let config = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)                 // == display backing scale
    config.width  = Int(filter.contentRect.width  * scale)     // contentRect == display bounds, points
    config.height = Int(filter.contentRect.height * scale)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.colorSpaceName = CGColorSpace.sRGB                   // or .displayP3
    config.showsCursor = false
    config.captureResolution = .best
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}
```

**(b) Arbitrary rect on a display** — `sourceRect` is **display-LOCAL points**, so subtract the display origin (both in CG global space):
```swift
func captureRect(globalRect: CGRect, on display: SCDisplay, exclude: [SCWindow]) async throws -> CGImage {
    let filter = SCContentFilter(display: display, excludingWindows: exclude)
    let config = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    let local = CGRect(x: globalRect.origin.x - display.frame.origin.x,
                       y: globalRect.origin.y - display.frame.origin.y,   // CG space: both top-left origin
                       width: globalRect.width, height: globalRect.height)
    config.sourceRect = local                                   // POINTS, display-local
    config.width  = Int((local.width  * scale).rounded())       // PIXELS — round, don't truncate
    config.height = Int((local.height * scale).rounded())
    config.showsCursor = false
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}
```
Selection spanning multiple displays: intersect with each `display.frame`, capture per display, stitch (upscale lower-DPI parts to the max scale) — or on 15.2+ use `captureImage(in: rect)` (accepting no exclusion/cursor control).

**(c) Single window:**
```swift
func captureWindow(_ window: SCWindow) async throws -> CGImage {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    config.width  = Int(filter.contentRect.width  * scale)     // contentRect = window bounds, points
    config.height = Int(filter.contentRect.height * scale)
    config.ignoreShadowsSingleWindow = true      // exact sizing only works shadow-free (see §2)
    config.ignoreGlobalClipSingleWindow = true   // don't clip parts hanging off-screen
    config.scalesToFit = false
    config.showsCursor = false
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}
```
Output has alpha (rounded corners transparent). For a CleanShot-style shadow, draw your own at composite time.

## 6. Coordinate spaces — THE bug class

Two global spaces share the same x-axis and differ only in y-flip:
- **CG / SCK "display space"** (`SCDisplay.frame`, `SCWindow.frame`, `CGDisplayBounds`, `CGEvent` locations, `captureImage(in:)`, `CGGetDisplaysWithPoint`): origin at **top-left of the primary display**, +y **down**.
- **AppKit screen space** (`NSScreen.frame`, `NSWindow.frame`, `NSEvent.mouseLocation`): origin at **bottom-left of the primary display**, +y **up**.

The flip reference is the **primary display's height in points** — the display whose AppKit origin is (0,0), i.e. `NSScreen.screens[0]` (documented: index 0 is the primary screen containing the menu bar). **NOT `NSScreen.main`** (that's the keyboard-focus screen — using it is the classic bug). Equivalent: `CGDisplayBounds(CGMainDisplayID()).height`.

```swift
// Same formula both directions (it is an involution). Works for ALL displays, negative coords included.
func flip(_ r: CGRect) -> CGRect {   // CG<->AppKit rect
    let h = NSScreen.screens[0].frame.height
    return CGRect(x: r.origin.x, y: h - r.origin.y - r.height, width: r.width, height: r.height)
}
func flip(_ p: CGPoint) -> CGPoint { // CG<->AppKit point (note: no height term)
    CGPoint(x: p.x, y: NSScreen.screens[0].frame.height - p.y)
}
```
Worked multi-display examples (primary = 1512×982 pt):
- Display **above** primary (1920×1080): CG frame `(0, -1080, 1920, 1080)` (y negative — up is −y in CG) ⇄ AppKit `(0, 982, 1920, 1080)` (sits on top of primary's top edge y=982).
- Display **left** of primary, top edges aligned: CG `(-1920, 0, 1920, 1080)` ⇄ AppKit `(-1920, -98, 1920, 1080)` — **AppKit y goes negative** because that display's bottom edge is 98 pt below the primary's bottom. Negative values are normal in both spaces; never clamp.
- Mouse: `NSEvent.mouseLocation` (AppKit) → CG: `flip(point)`. That CG point feeds `CGGetDisplaysWithPoint` / selection rects.

Helpers (typechecked):
```swift
func screenFor(displayID: CGDirectDisplayID) -> NSScreen? {   // SCDisplay -> NSScreen
    NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
    }
}
func displayID(atCGPoint p: CGPoint) -> CGDirectDisplayID? {  // which display owns a CG point
    var id: CGDirectDisplayID = 0; var n: UInt32 = 0
    return CGGetDisplaysWithPoint(p, 1, &id, &n) == .success && n > 0 ? id : nil
}
```
Rules of thumb: overlay windows are positioned with AppKit rects (flip CG→AppKit); everything you hand to SCK (`sourceRect` after making it display-local, `captureImage(in:)`) is CG-space points (flip AppKit→CG). `SCWindow.frame` ↔ `NSWindow.frame` need the flip; matching by `windowID == CGWindowID(nsWindow.windowNumber)` avoids it.

## 7. Permission (Screen Recording TCC)

```swift
// CoreGraphics, both macOS 10.15+, synchronous:
CGPreflightScreenCaptureAccess() -> Bool   // check only, NEVER prompts
CGRequestScreenCaptureAccess()  -> Bool    // returns true if already granted; otherwise shows the system
                                           // prompt (first time only) and returns false immediately
```
Menu-bar app flow:
```swift
@discardableResult
func ensurePermission() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    if CGRequestScreenCaptureAccess() { return true }       // may pop the one-time system dialog
    NSWorkspace.shared.open(URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    return false
}
```
- Deep link verified: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` opens **System Settings → Privacy & Security → Screen & System Audio Recording** on Ventura through current macOS.
- Preflight at launch (drives menu-item enabled state); call `CGRequestScreenCaptureAccess()` lazily on first capture attempt. After the user flips the toggle, **macOS requires the app to relaunch** (System Settings offers "Quit & Reopen"). Poll `CGPreflightScreenCaptureAccess()` on a 1–2 s timer while your onboarding window is up and offer a Relaunch button.
- SCK alternative: any `SCShareableContent` fetch both triggers the prompt (first time) and, when denied, throws `SCStreamError.Code.userDeclined` (rawValue **-3801**, domain `SCStreamErrorDomain`). Catch:
```swift
catch let e as NSError where e.domain == SCStreamErrorDomain
                          && e.code == SCStreamError.Code.userDeclined.rawValue { ... }
```
Prefer the CG pair for flow control (synchronous, no throw); use the error catch as backstop.
- Other codes (SCError.h): -3802 failedToStart, -3803 missingEntitlements, -3812 invalidParameter, -3813/-3814 noWindowList/noDisplayList, -3815 noCaptureSource, -3817 userStopped, -3821 systemStoppedStream (15.0+).
- **macOS 15 Sequoia nag:** apps holding the Screen Recording grant get a periodic re-confirmation dialog ("Allow For One Month"), monthly + after some reboots; 15.1 reduced frequency for regularly-used apps. Cannot be suppressed programmatically (MDM only). Expected behaviour for a CleanShot clone — handle gracefully, don't treat as an error.
- **swiftc/no-Xcode gotcha:** TCC keys the grant to the app's identity. Ship a real `.app` bundle with a stable bundle ID and a **stable code signature** (self-signed cert or consistent identity; plain ad-hoc re-signing each build changes CDHash and can invalidate/re-prompt the grant). Running a bare binary from a terminal attributes the permission to the *terminal*, not your app.

## 8. CGImage → file and pasteboard

**Files — use ImageIO, not NSBitmapImageRep** (Apple DTS: `NSBitmapImageRep` PNG output is ~10× larger than `screencapture`'s for the same pixels):
```swift
import ImageIO, UniformTypeIdentifiers
func writePNG(_ image: CGImage, to url: URL, scale: CGFloat) throws {  // scale = pointPixelScale
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
        UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    let props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72.0 * scale,   // 144 on 2x retina:
                                  kCGImagePropertyDPIHeight: 72.0 * scale]  // Preview then reports point size, like ⌘⇧3
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}
func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
        UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(dest, image,
        [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}
func pngData(_ image: CGImage) -> Data? {           // in-memory, for the pasteboard
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
}
```
(JPEG can't hold alpha — flatten first or capture with `shouldBeOpaque = true`.)

**Pasteboard — one `NSPasteboardItem` carrying multiple representations** so every paste target picks what it understands (Finder → file URL copy; Slack/Chromium → `public.png`; Preview "New from Clipboard"/legacy Cocoa → TIFF/PNG):
```swift
func copyToPasteboard(image: CGImage, pngData: Data, fileURL: URL) {
    let pb = NSPasteboard.general
    pb.clearContents()                                       // mandatory before writing
    let item = NSPasteboardItem()
    item.setData(pngData, forType: .png)                     // "public.png"
    if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
        item.setData(tiff, forType: .tiff)                   // widens compatibility with older Cocoa apps
    }
    item.setString(fileURL.absoluteString, forType: .fileURL) // "public.file-url" — Finder pastes the file
    pb.writeObjects([item])
}
```
Order of operations: **write the file to disk first**, then put its URL on the pasteboard (a dangling file URL breaks Finder paste). Don't use `pb.writeObjects([nsImage, url as NSURL])` — that creates two pasteboard items and some apps paste both/behave oddly; keep it one item, many representations. If the user chose "copy only, no file", omit the `.fileURL` representation entirely.

## 9. macOS 26 path (guard `#available(macOS 26.0, *)`) — optional upgrade

`SCScreenshotConfiguration` (defaults = content size; `width/height` in **pixels**; `sourceRect` in **points**, display-local): `showsCursor`, `ignoreShadows`, `ignoreClipping`, `includeChildWindows`, `displayIntent` (`.canonical/.local`), `dynamicRange` (`.sdr/.hdr/.bothSDRAndHDR`), `contentType` (PNG/JPEG/HEIC), `fileURL` (writes the file for you). `SCScreenshotOutput`: `sdrImage: CGImage?`, `hdrImage: CGImage?`, `fileURL`.
Bridging gotchas found by typechecking: `contentType` imports as `UTTypeReference` (use `UTTypeReference(UTType.png.identifier)!`) **and the property is `assign`/`unowned(unsafe)` in this SDK — keep a strong reference to the UTTypeReference for the config's lifetime or it deallocates immediately** (compiler warns); `output.fileURL` imports as `NSURL?`.

## 10. Top gotchas recap

1. `SCStreamConfiguration.width/height` default **1920×1080** — forgetting to set them silently produces a scaled 1080p still.
2. `width/height` are **pixels**; `sourceRect` is **points in the filter-content-local space** (subtract `display.frame.origin` for global rects); `destinationRect` is pixels.
3. Flip formula uses `NSScreen.screens[0].frame.height` (primary), never `NSScreen.main`; rect flip subtracts height, point flip doesn't; coordinates legitimately go negative on multi-display rigs.
4. `sharingType = .none` no longer hides your overlay from SCK on macOS 15+ — exclude via filter, or hide the overlay for a frame when using `captureImage(in:)`.
5. Window stills: pixel-exact sizing requires `ignoreShadowsSingleWindow = true`; there's no API for the shadow margin — composite your own shadow.
6. `showsCursor` defaults **true**; stills usually want false.
7. PNG-encode with ImageIO (`CGImageDestination`), not `NSBitmapImageRep` (~10× file size).
8. Permission grant requires app relaunch; Sequoia re-prompts periodically; stable bundle+signature or TCC forgets you.
9. `captureImage(in:)` is 15.2+, not 15.0 — `#available` guard it; output scale UNVERIFIED, assert on `image.width` in debug.

Sources: MacOSX26.5 SDK headers (SCScreenshotManager.h / SCStream.h / SCShareableContent.h / SCError.h / CGWindow.h); Apple dev forums 755819 (DTS, ImageIO PNG), 792152 + tauri-apps/tauri#14200 (sharingType on 15+); developer.apple.com SCScreenshotConfiguration (26.0); rmcdongit prefs-URL gist + derflounder (deep link); MacRumors/9to5Mac/TidBITS (Sequoia re-prompt).