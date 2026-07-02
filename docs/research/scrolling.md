# Scrolling capture (CleanShot-X style) — implementation cheat-sheet

## 1. CleanShot X scrolling-capture UX (researched from cleanshot.com + changelog + third-party writeups)

**Flow (verified from CleanShot docs/changelog + user writeups):**
1. Trigger: menu-bar item "Scrolling Capture", user hotkey (commonly Shift-Opt-Cmd-4), or URL scheme `cleanshot://scrolling-capture` (params: `x, y, width, height, display`; `start=true/false` auto-starts capture; `autoscroll=true/false` enables auto-scroll — those two need CleanShot >= 4.7; the command itself >= 3.5.1).
2. User **drags a selection rectangle** around the scrollable area (typically a browser window's content area).
3. Overlay shows a **"Start Capture"** button. User clicks it.
4. Then either the **user scrolls manually** (trackpad/wheel; this was the only mode originally) **or clicks an "Auto-Scroll" button** — auto-scroll was added in **CleanShot 4.6 (5 Sep 2023)** ("Added Auto-Scroll option to Scrolling Capture"). With auto-scroll, the app scrolls the content itself and the user "clicks Done when it finishes".
5. User clicks **"Done"** to end; the stitched tall image lands in CleanShot's usual floating Quick Access Overlay (bottom-left) for annotate/save/copy.
- Horizontal scrolling capture exists since **4.8 (27 May 2025)**.
- Changelog 3.8 (2021): "Added warning when scrolling capture is too long" — i.e. they cap/warn on extreme heights.
- **Fixed/sticky headers: CleanShot does NOT remove them.** Third-party review (scottwillsey.com) explicitly notes sticky menus "look long and repetitive" — duplicated in the output. So parity does not require header removal, but doing exclusion-band matching (Section 3) is an easy differentiator.
- UNVERIFIED: exact in-capture progress UI (whether a live-updating stitched preview is shown vs just the selection overlay + buttons); whether auto-scroll auto-stops at page end (implied by "click Done when it finishes"); how backwards scrolling is treated.

**Recommended UX for us:** select region → "Start Capture" → capture frames continuously while user scrolls (or auto-scroll) → "Done" button + auto-stop after N still frames in auto-scroll mode → stitched image to our overlay.

Capture side note: grab the fixed region repeatedly with ScreenCaptureKit (`SCScreenshotManager.captureImage(contentFilter:configuration:)` polled ~10 Hz, or an `SCStream` with `minimumFrameInterval`); needs **Screen Recording** TCC (separate from Accessibility below).

## 2. Vision framework — image registration (both APIs verified live, July 2026)

### Old ObjC-era API — `VNTranslationalImageRegistrationRequest` — **NOT deprecated**, macOS 10.13+
- `class VNTranslationalImageRegistrationRequest : VNImageRegistrationRequest` (which is a `VNTargetedImageRequest`). Sibling: `VNHomographicImageRegistrationRequest` (don't use — full homography, overkill and less stable for pure scroll).
- Init (inherited): `init(targetedCGImage: CGImage, options: [VNImageOption : Any])` (+ `orientation:` and `completionHandler:` variants; also `targetedCVPixelBuffer:` / `targetedCIImage:`).
- `var results: [VNImageTranslationAlignmentObservation]?`
- `VNImageTranslationAlignmentObservation.alignmentTransform: CGAffineTransform` — Apple: "The alignment transform to **align the floating image with the reference image**." Floating = the *targeted* image passed to the request init; reference = the image the `VNImageRequestHandler` is created with.

```swift
import Vision
// translation of `current` relative to `previous`
func translation(previous: CGImage, current: CGImage) throws -> CGPoint {
    let req = VNTranslationalImageRegistrationRequest(targetedCGImage: current, options: [:])
    try VNImageRequestHandler(cgImage: previous, options: [:]).perform([req])
    guard let t = req.results?.first?.alignmentTransform else { throw CaptureError.noAlignment }
    return CGPoint(x: t.tx, y: t.ty)   // in practice integer pixel values (community-reported, UNVERIFIED)
}
```

### New Swift-only API — `TrackTranslationalImageRegistrationRequest` — **macOS 15.0+** (fits our 15+ target), WWDC24 "Discover Swift enhancements in the Vision framework" (session 10163)
- `final class TrackTranslationalImageRegistrationRequest` — Sendable, conforms to `StatefulRequest`, `TargetedRequest`, `ImageProcessingRequest`, `VisionRequest`.
- `init(_ revision: TrackTranslationalImageRegistrationRequest.Revision? = nil, frameAnalysisSpacing: CMTime? = nil)`
- `func perform(on:orientation:) async throws -> ImageTranslationAlignmentObservation` — 6 overloads: `URL`, `Data`, `CGImage`, `CVPixelBuffer`, `CMSampleBuffer`, `CIImage`; `orientation: CGImagePropertyOrientation?` (optional).
- Result: `struct ImageTranslationAlignmentObservation` with `let alignmentTransform: CGAffineTransform` ("align the floating image with the reference image") and `func applyTransform(to: CIImage) -> CIImage`.
- **Stateful**: keep ONE request instance, call `perform` on frames in temporal order; each call aligns the new frame against the internally-retained previous frame. `StatefulRequest` also exposes `frameAnalysisSpacing: CMTime` and `minimumLatencyFrameCount: Int`.

```swift
import Vision
let tracker = TrackTranslationalImageRegistrationRequest()
for frame in frames {                      // temporal order, single instance
    let obs = try await tracker.perform(on: frame)      // frame: CGImage
    let dy = obs.alignmentTransform.ty                   // dx should be ~0 for vertical scroll
}
```
- UNVERIFIED: what the very first `perform` returns (identity vs undefined — treat frame 0's observation as identity/ignore it); exact sign convention of `ty` vs scroll direction. **Calibrate at runtime**: crop two strips with a known offset from one tall test image, assert the sign once in dev, encode as a unit test.

**Accuracy/constraints (both APIs):** translation-only, assumes the two images are largely the *same content shifted*; robust and fast for scroll stitching (this is exactly its use case — panorama/photo-stacking). Fails or returns garbage on: repeated patterns (tables, zebra rows), large flat regions, animated GIFs/video/ads inside the region, < ~20-30% overlap. **Always sanity-check the result**: reject if `|dx| > 2 px`, `|dy| > maxPlausibleScroll` (e.g. 0.9 × region height), or the frame is near-uniform — and fall back to Section 3's matcher for that frame pair. There is no confidence score on the observation, so plausibility checks are the only guard.

## 3. Fallback: grayscale row-band NCC with Accelerate/vDSP

Idea: downsample each frame to a narrow grayscale column-profile (full height × ~64 px wide), then slide a band of the previous frame over the current frame and pick the offset with max normalised cross-correlation.

```swift
import Accelerate

struct FrameProfile { let width: Int; let height: Int; let px: [Float] } // row-major gray

func profile(of image: CGImage, sampleWidth: Int = 64) -> FrameProfile {
    let h = image.height
    let ctx = CGContext(data: nil, width: sampleWidth, height: h,
                        bitsPerComponent: 8, bytesPerRow: sampleWidth,
                        space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.interpolationQuality = .low
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: h))
    let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)   // row 0 = top scanline
    var f = [Float](repeating: 0, count: sampleWidth * h)
    vDSP_vfltu8(bytes, 1, &f, 1, vDSP_Length(sampleWidth * h))
    return FrameProfile(width: sampleWidth, height: h, px: f)
}

/// dy > 0 = user scrolled down (content moved up); dy < 0 = scrolled back up.
func verticalOffset(prev: FrameProfile, curr: FrameProfile,
                    headerPx: Int, footerPx: Int,
                    bandRows: Int = 160, maxScroll: Int = 1200) -> (dy: Int, score: Float)? {
    let w = prev.width, h = prev.height
    let usableEnd = h - footerPx
    let tStart = max(headerPx, usableEnd - bandRows)      // band anchored just above footer
    let rows = usableEnd - tStart, n = rows * w
    var tNorm = [Float](repeating: 0, count: n)
    var m: Float = 0, sd: Float = 0
    prev.px.withUnsafeBufferPointer { p in
        vDSP_normalize(p.baseAddress! + tStart * w, 1, &tNorm, 1, &m, &sd, vDSP_Length(n))
    }
    guard sd > 1e-3 else { return nil }                    // flat band, unmatchable
    var best: (dy: Int, score: Float) = (0, -2)
    var cNorm = [Float](repeating: 0, count: n)
    for dy in (-maxScroll / 4)...maxScroll {               // small negative range = backwards scroll
        let r = tStart - dy                                // band lands here in current frame
        guard r >= headerPx, r + rows <= usableEnd else { continue }
        curr.px.withUnsafeBufferPointer { p in
            vDSP_normalize(p.baseAddress! + r * w, 1, &cNorm, 1, &m, &sd, vDSP_Length(n))
        }
        guard sd > 1e-3 else { continue }
        var dot: Float = 0
        vDSP_dotpr(tNorm, 1, cNorm, 1, &dot, vDSP_Length(n))
        let ncc = dot / Float(n)                           // zero-mean unit-sd → Pearson r
        if ncc > best.score { best = (dy, ncc) }
    }
    return best.score > 0.9 ? best : nil                   // < 0.9 → animated/unreliable, skip frame
}
```
- Speed: ~1500 candidates × 10k floats each — a few ms with vDSP. Optional coarse-to-fine: stride 4 over dy, then refine ±4.
- **Fixed headers/footers:** exclude bands via `headerPx`/`footerPx`. Auto-detect: once motion is confirmed (dy != 0), compute per-row |diff| between consecutive frames; contiguous top rows whose diff stays ~0 across >= 3 moving frames = sticky header height (same from the bottom = footer). Recompute occasionally; keep the max seen.
- **No-motion frame:** best dy == 0 with high score → drop frame, continue.
- **Backwards scroll:** dy < 0 → user scrolled up over already-captured content: don't stitch, just update `cumulativeOffset += dy`; new pixels are appended only when `cumulativeOffset + frameUsableHeight > capturedBottom`.
- **End-of-page (auto-scroll):** after each synthetic scroll + settle, if K consecutive frames yield dy == 0 (K ≈ 3-5), the page hit bottom → stop automatically.
- vDSP functions used (all long-standing C vDSP, in Accelerate): `vDSP_vfltu8` (UInt8→Float), `vDSP_normalize` (outputs zero-mean/unit-sd copy + returns mean/sd), `vDSP_dotpr` (dot product). Swift overlay equivalents exist (`vDSP.mean`, `vDSP.dot`) but the C calls above are the verified-stable spellings.

## 4. Compositing the tall image

- Don't retain whole frames. Per accepted frame keep only the **newly revealed strip**: `frame.cropping(to: CGRect(x: 0, y: stripTopInFrame, width: w, height: stripH))` (`CGImage.cropping(to:)` shares backing memory — cheap) plus its document-space top offset. Crop the header band off every frame except the first; take the footer from the last frame.
- Composite once at "Done", when total height is known:

```swift
func composite(strips: [(image: CGImage, top: Int)], width: Int, totalHeight: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: totalHeight,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    for s in strips {                              // CG origin bottom-left; `top` is from document top
        let y = totalHeight - s.top - s.image.height
        ctx.draw(s.image, in: CGRect(x: 0, y: y, width: s.image.width, height: s.image.height))
    }
    return ctx.makeImage()
}
```
- **Memory:** canvas = `width × totalHeight × 4` bytes. Retina 2400 px wide × 50,000 px tall ≈ 480 MB. Practical policy: warn at ~30,000 px document height and hard-stop around ~60,000 px / ~500 MB canvas (CleanShot likewise "warns when scrolling capture is too long"). No hard CGImage dimension limit at these sizes (memory-bound), but:
  - **JPEG cannot exceed 65,500 px per side** — export tall captures as **PNG** (or TIFF). (JPEG limit is libjpeg-standard; UNVERIFIED against Apple's exact encoder cap.)
  - Save: `CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)` → `CGImageDestinationAddImage` → `CGImageDestinationFinalize`.
  - For preview UI, downscale — don't hand a 60k-px NSImage to a live layer.

## 5. Auto-scroll via synthetic scroll events + the permission answer

```swift
// verified signature, macOS 10.13+ (maps to CGEventCreateScrollWheelEvent2)
init?(scrollWheelEvent2Source source: CGEventSource?, units: CGScrollEventUnit,
      wheelCount: UInt32, wheel1: Int32, wheel2: Int32, wheel3: Int32)

func postScroll(pixels: Int32, at point: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                           wheelCount: 1, wheel1: -pixels, wheel2: 0, wheel3: 0) else { return }
    ev.location = point
    ev.post(tap: .cghidEventTap)
}
```
- `CGScrollEventUnit`: `.pixel` (smooth scrolling; default scale ~10 px/line) or `.line`. Use `.pixel`, increments of ~40-120 px, 100-200 ms apart, capture after each settles.
- Sign: negative `wheel1` scrolls toward page bottom (community convention — UNVERIFIED; calibrate at runtime like the Vision sign).
- Routing: macOS delivers scroll events to the window under the cursor; setting `ev.location` alone may not retarget in all apps — if flaky, `CGWarpMouseCursorPosition(point)` into the capture region first (UNVERIFIED which is required per app).

**Permission: YES — posting synthetic events requires the Accessibility TCC grant.** Since macOS 10.14, `CGEventPost`/`CGEvent.post` of synthetic input is gated on assistive access; the user must enable the app under **System Settings > Privacy & Security > Accessibility**. Multiple corroborating sources (Apple forums "CGEventPost doesn't work in 10.14", Jamf/HackTricks security writeups). So the plan stands: **ship manual-scroll first; auto-scroll behind a permission gate.**

```swift
if !CGPreflightPostEventAccess() {            // silent check, macOS 10.15+, verified
    let granted = CGRequestPostEventAccess()  // prompts + adds app to the Accessibility list, macOS 10.15+, verified
    guard granted else { /* fall back to manual-scroll mode */ return }
}
```
- Classic alternative check: `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)` (ApplicationServices).
- Plain-`swiftc` gotcha: TCC grants are keyed to the code signature — an **ad-hoc-signed binary changes CDHash every rebuild and the Accessibility grant silently resets**. Sign with a stable Developer ID (or at least a persistent self-signed identity) during development. (Known TCC behaviour; exact reset semantics UNVERIFIED for macOS 26.)
- Screen capture itself needs the separate **Screen Recording** permission — two prompts total when auto-scroll is enabled.

## Suggested pipeline wiring
1. Region select → `SCStream`/polled `SCScreenshotManager` on the fixed region (~10 Hz).
2. Per frame: `TrackTranslationalImageRegistrationRequest.perform(on:)` → dy; plausibility-check (|dx| <= 2, dy bounds); on failure, vDSP NCC fallback for that pair; on both failing, drop frame.
3. Accumulate offsets; store cropped new-content strips (header/footer excluded).
4. Stop on Done click, or K still frames in auto-scroll.
5. Composite into one sRGB CGContext, `makeImage()`, PNG out.

Sources: [TrackTranslationalImageRegistrationRequest](https://developer.apple.com/documentation/vision/tracktranslationalimageregistrationrequest) · [init(_:frameAnalysisSpacing:)](https://developer.apple.com/documentation/vision/tracktranslationalimageregistrationrequest/init(_:frameanalysisspacing:)) · [ImageTranslationAlignmentObservation](https://developer.apple.com/documentation/vision/imagetranslationalignmentobservation) · [VNTranslationalImageRegistrationRequest](https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest) · [VNImageTranslationAlignmentObservation](https://developer.apple.com/documentation/vision/vnimagetranslationalignmentobservation) · [VNTargetedImageRequest](https://developer.apple.com/documentation/vision/vntargetedimagerequest) · [StatefulRequest](https://developer.apple.com/documentation/vision/statefulrequest) · [CGEvent scrollWheelEvent2Source init](https://developer.apple.com/documentation/coregraphics/cgevent/init(scrollwheelevent2source:units:wheelcount:wheel1:wheel2:wheel3:)) · [CGScrollEventUnit](https://developer.apple.com/documentation/coregraphics/cgscrolleventunit) · [CGPreflightPostEventAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess()) · [CGRequestPostEventAccess](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()) · [CleanShot changelog](https://cleanshot.com/changelog) · [CleanShot URL scheme API](https://cleanshot.com/docs-api) · [CleanShot features](https://cleanshot.com/features) · [Scrolling Screenshots in CleanShot X (scottwillsey.com)](https://scottwillsey.com/cleanshotx-scrolling-screenshots/) · [WWDC24 session 10163](https://developer.apple.com/videos/play/wwdc2024/10163/) · [Jamf: Synthetic Reality](https://www.jamf.com/blog/synthetic-reality/) · [Apple forums: CGEventPost in 10.14](https://developer.apple.com/forums/thread/103992)