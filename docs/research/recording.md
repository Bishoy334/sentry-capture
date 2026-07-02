# ScreenCaptureKit recording cheat-sheet — macOS 15+ (Sentry Capture)

Deployment target macOS 15+ means **every API below is usable unguarded** unless marked otherwise. Link flags for plain `swiftc`:
`-framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -framework AppKit`

---

## 1. SCRecordingOutput vs SCStream+AVAssetWriter — RECOMMENDATION: SCRecordingOutput

| | SCRecordingOutput (macOS 15+) | SCStream outputs + AVAssetWriter (12.3+) |
|---|---|---|
| Code | ~30 lines; OS does muxing/AV-sync | ~200+ lines; you own PTS, sync, session timing |
| Region / window capture | yes (comes from filter+config, identical both paths) | yes |
| System audio + mic | yes, just flip config bools | yes, but you wire 3 sample-buffer callbacks + 2–3 writer inputs |
| Container / codec | `.mp4` (default) or `.mov`; `.h264` (default) or `.hevc` — **defaults are exactly what we want** | anything AVAssetWriter supports |
| Bitrate / keyframe / quality control | **none** (codec+container+URL only) | full `AVVideoCompressionPropertiesKey` |
| Pause/resume | **no API** | implementable (drop buffers + retime PTS) |
| Live frame access (preview, live thumbnail) | not via this object — but you can `addStreamOutput` on the *same* stream alongside it | inherent |
| Mic on separate audio track | not controllable on 15/26 (see `mixesAudioWithMicrophone`, macOS 27 beta only) | you decide (extra audio input) |

**Recommend `SCRecordingOutput`.** It meets every stated requirement (arbitrary region or single window, optional system audio, optional mic, clean menu-bar stop, .mp4 H.264/HEVC) with an order of magnitude less code and zero AV-sync bugs. Revisit AVAssetWriter only if pause/resume or bitrate control becomes a requirement (CleanShot has pause — if you want that later, the writer path below is the escape hatch; both can even run in parallel phases since filter/config code is shared).

### 1a. Full minimal pipeline (recommended path)

```swift
import ScreenCaptureKit
import AVFoundation

final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private(set) var stream: SCStream?
    private(set) var recordingOutput: SCRecordingOutput?
    var onFinished: ((URL) -> Void)?          // file finalised, safe to use
    var onFailed: ((Error) -> Void)?
    var onExternallyStopped: (() -> Void)?    // user hit stop in the system UI
    private var outputURL: URL!

    // -- Permission (CoreGraphics, macOS 10.15+). Prompt result requires app relaunch to take effect.
    static func hasScreenPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestScreenPermission() { CGRequestScreenCaptureAccess() }

    // region: display-LOCAL points, origin top-left (see §3). Pass window OR region, not both.
    func start(display: SCDisplay, region: CGRect?, window: SCWindow?,
               systemAudio: Bool, microphone: Bool, to url: URL) async throws {
        outputURL = url
        // 1. Filter
        let filter: SCContentFilter = window != nil
            ? SCContentFilter(desktopIndependentWindow: window!)
            : SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)      // macOS 14+; 2.0 on retina

        // 2. Stream config
        let config = SCStreamConfiguration()
        if let region {                                   // ignored for window filters
            config.sourceRect = region                    // points, display-local
            config.width  = Int(region.width  * scale) & ~1   // even dims for H.264
            config.height = Int(region.height * scale) & ~1
        } else {
            config.width  = Int(filter.contentRect.width  * scale) & ~1
            config.height = Int(filter.contentRect.height * scale) & ~1
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)  // 60 fps cap
        config.queueDepth = 5
        config.showsCursor = true
        config.capturesAudio = systemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = microphone            // macOS 15+
        if microphone {                                  // needs NSMicrophoneUsageDescription + AVCaptureDevice.requestAccess(for: .audio)
            config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        // 3. Stream + recording output
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url            // ensure no file already exists at url
        recConfig.outputFileType = .mp4      // default is already .mp4 (AVFileTypeMPEG4)
        recConfig.videoCodecType = .h264     // default is already H.264; .hevc also supported
        let rec = SCRecordingOutput(configuration: recConfig, delegate: self)
        try stream.addRecordingOutput(rec)   // throws
        try await stream.startCapture()      // also: startCapture(completionHandler:)
        self.stream = stream; self.recordingOutput = rec
    }

    func stop() async {
        guard let s = stream else { return }             // guards .attemptToStopStreamState
        stream = nil
        try? await s.stopCapture()           // finalises the file -> didFinishRecording fires
    }

    // MARK: SCRecordingOutputDelegate (all three are required methods)
    func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        // fires async after addRecordingOutput — start the menu-bar timer HERE
    }
    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        stream = nil; onFailed?(error)       // disk full etc.; file may still be partially playable
    }
    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        onFinished?(outputURL)               // fires after stopCapture OR removeRecordingOutput
    }

    // MARK: SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        let code = SCStreamError.Code(rawValue: (error as NSError).code)
        if code == .userStopped { onExternallyStopped?() }   // intentional, not an error (per Apple docs)
        else { onFailed?(error) }
    }
}
```

Key facts (verified):
- `SCRecordingOutput(configuration:delegate:)` — only init; `var recordedDuration: CMTime`, `var recordedFileSize: Int` (bytes) — poll these for the menu-bar timer / size readout.
- `SCStream.addRecordingOutput(_:) throws` / `removeRecordingOutput(_:) throws`. `removeRecordingOutput` = stop recording but keep the stream running (e.g. keep the picker/preview alive).
- Header-doc defaults: `outputFileType` default `AVFileTypeMPEG4` (.mp4), `videoCodecType` default `AVVideoCodecTypeH264`. Query `availableOutputFileTypes: [AVFileType]` / `availableVideoCodecTypes: [AVVideoCodecType]` at runtime.
- `mixesAudioWithMicrophone: Bool` on SCRecordingOutputConfiguration exists but is **macOS 27 beta only** — NOT usable at target 15. UNVERIFIED whether 15/26 writes mic as a separate track or mixes; test once and don't rely on it.
- Delegate callbacks arrive on an internal queue — hop to main before touching AppKit. Under Swift 6 strict concurrency mark the recorder `@unchecked Sendable` or route through `Task { @MainActor in … }`.
- Same stream can additionally take `addStreamOutput(_:type:sampleHandlerQueue:)` (`.screen`/`.audio`/`.microphone` — `.microphone` is macOS 15+) for live preview while SCRecordingOutput records.

Content discovery:
```swift
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
// content.displays: [SCDisplay] (displayID: CGDirectDisplayID, frame: CGRect in global top-left-origin points, width/height: Int POINTS)
// content.windows: [SCWindow], content.applications: [SCRunningApplication]
```

### 1b. AVAssetWriter path (only if pause/bitrate needed) — condensed

```swift
let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000,
                                      AVVideoExpectedSourceFrameRateKey: 60,
                                      AVVideoMaxKeyFrameIntervalKey: 120]])
video.expectsMediaDataInRealTime = true
let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
audio.expectsMediaDataInRealTime = true
writer.add(video); writer.add(audio)   // + a 2nd audio input for a separate mic track
// addStreamOutput for .screen/.audio/.microphone; in the .screen callback:
guard let atts = CMSampleBufferGetSampleAttachmentsArray(buf, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
// first complete frame: writer.startWriting(); writer.startSession(atSourceTime: buf.presentationTimeStamp)
// then: if video.isReadyForMoreMediaData { video.append(buf) }
// stop: try await stream.stopCapture(); inputs.markAsFinished(); await writer.finishWriting()
```
Gotchas: SCK screen buffers arrive with status `.idle`/`.blank` repeats — writing them corrupts timing; always gate on `.complete`. Never block the sampleHandlerQueue.

---

## 2. SCStreamConfiguration field reference (video/audio)

| Property | Type | Since | Default / notes |
|---|---|---|---|
| `width` / `height` | `Int` | 12.3 | output size in **pixels** (config values, not points) |
| `minimumFrameInterval` | `CMTime` | 12.3 | `.zero` = max supported rate; `CMTime(value: 1, timescale: 60)` = cap 60 fps |
| `queueDepth` | `Int` | 12.3 | default 3, range 3–8 (docs: never exceed 8); Apple sample uses 5 for high fps |
| `showsCursor` | `Bool` | 12.3 | true by default |
| `showMouseClicks` | `Bool` | **15.0** | draws click highlight rings |
| `scalesToFit` / `preservesAspectRatio` / `destinationRect` | | 12.3 | placement of content inside output frame; leave defaults for 1:1 region capture |
| `pixelFormat` | `OSType` | 12.3 | 'BGRA' default; '420v'/'420f'/'l10r' available — irrelevant for SCRecordingOutput |
| `capturesAudio` | `Bool` | 13.0 | false by default (system audio) |
| `sampleRate` | `Int` | 13.0 | supported: 8000/16000/24000/48000; default + fallback for bad values = 48000 |
| `channelCount` | `Int` | 13.0 | default 2 |
| `excludesCurrentProcessAudio` | `Bool` | 13.0 | set true so our own shutter sounds don't get recorded |
| `captureMicrophone` | `Bool` | **15.0** | false by default |
| `microphoneCaptureDeviceID` | `String?` | **15.0** | `AVCaptureDevice.uniqueID`; nil = system default mic |
| `captureResolution` | `SCCaptureResolutionType` | 14.0 | `.automatic` (default) / `.best` / `.nominal` |
| `captureDynamicRange` | `SCCaptureDynamicRange` | 15.0 | `.sdr` default; `.hdrLocalDisplay` / `.hdrCanonicalDisplay` (HEVC only) — skip for a v1 |
| `queue/color extras` | `colorSpaceName`, `colorMatrix`, `backgroundColor: CGColor` | 12.3 | backgroundColor default clear — set `CGColor.black` behind non-opaque windows |
| preset init | `SCStreamConfiguration(preset:)` | 15.0 | HDR stream/screenshot presets only |

---

## 3. Arbitrary sub-rect of a display + retina

- `sourceRect: CGRect` (12.3+): crop rectangle in **points, in the display's local coordinate space, origin at the display's top-left** (CoreGraphics-style, y-down). Unset = whole display. **Ignored for `desktopIndependentWindow` filters** (window filters always capture full window bounds).
- `width`/`height` are the **output pixel dimensions** — SCK scales `sourceRect` content into them. For pixel-perfect retina: `width = sourceRect.width * scale`, `height = sourceRect.height * scale` where `scale = filter.pointPixelScale` (`Float`, macOS 14+; `filter.contentRect` gives the filter's size in points). Fallback: `NSScreen.backingScaleFactor`. If you set width/height in points, output is soft (1x) on retina — the classic bug.
- Keep dimensions even (`& ~1`) — H.264/HEVC 4:2:0 subsampling; odd sizes can fail or pad.
- Converting a selection made in an AppKit overlay window (bottom-left-origin global coords) to display-local top-left coords:
```swift
// selectionGlobal: NSRect in AppKit global space; display: SCDisplay (frame is CG top-left global)
let primaryH = NSScreen.screens[0].frame.height        // primary screen defines the flip
let cgGlobal = CGRect(x: selectionGlobal.minX,
                      y: primaryH - selectionGlobal.maxY,
                      width: selectionGlobal.width, height: selectionGlobal.height)
let local = CGRect(x: cgGlobal.minX - display.frame.minX,
                   y: cgGlobal.minY - display.frame.minY,
                   width: cgGlobal.width, height: cgGlobal.height)
```
- One stream = one display. A region spanning two displays can't be one recording — snap the selection UI to a single display (CleanShot does the same).
- Historical gotcha: `SCContentFilter(display:excludingWindows: [])` with an empty array once produced zero samples on some macOS builds — the `excludingApplications: [], exceptingWindows: []` form (used by Apple's current sample) is the safe spelling.

---

## 4. Failure modes and what fires

Error domain: `SCStreamErrorDomain`, Swift `SCStreamError.Code`. Full case list (all macOS 12.3+ unless noted): `userDeclined` (no Screen Recording TCC), `userStopped` (**treat as intentional stop, not an error** — Apple docs say exactly this), `failedToStart`, `attemptToStartStreamState`, `attemptToStopStreamState` (double-stop), `attemptToConfigState`, `attemptToUpdateFilterState`, `noCaptureSource`, `noDisplayList`, `noWindowList`, `removingStream`, `failedToStartAudioCapture`, `failedToStopAudioCapture`, `failedApplicationConnectionInvalid`, `failedApplicationConnectionInterrupted`, `failedNoMatchingApplicationContext`, `internalError`, `invalidParameter`, `insufficientStorage`, `notSupported`, `missingEntitlements`, `missingBackgroundMode`, and macOS 15 additions `failedToStartMicrophoneCapture` (= -3820) and `systemStoppedStream` (= -3821).

| Scenario | What fires |
|---|---|
| User clicks stop in the system purple-indicator UI | `stream(_:didStopWithError:)` with `.userStopped`. Recording output should still finalise — expect `recordingOutputDidFinishRecording` (ordering vs the stream callback UNVERIFIED; handle whichever comes and verify the file plays). Treat as a normal stop: update menu bar, keep the file. |
| Display disconnected mid-record | Not documented. Expect `didStopWithError` — candidates `.noCaptureSource` / `.systemStoppedStream` / `.failedApplicationConnectionInvalid` (which one: UNVERIFIED — test on hardware). Belt-and-braces: observe `NSApplication.didChangeScreenParametersNotification` and, if the recorded `displayID` vanished, call `stop()` yourself to finalise cleanly first. |
| Recorded *window* closes mid-record | Not documented; expect a stop with error (UNVERIFIED code). Same handling path. |
| Disk full | `recordingOutput(_:didFailWithError:)` — expect `.insufficientStorage` (mapping UNVERIFIED). Preflight with `url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])` and watch `recordedFileSize` during long recordings. |
| Mic busy / mic permission denied | `.failedToStartMicrophoneCapture` (-3820) at start. Request `AVCaptureDevice.requestAccess(for: .audio)` before starting. |
| Stop called twice | `.attemptToStopStreamState` — guard with a state machine (nil out `stream` before awaiting stopCapture). |

Universal rule: route **all** of `didStopWithError` / `didFailWithError` / `didFinishRecording` into one terminal "recording ended" path that (a) clears state, (b) resets the menu-bar item, (c) checks whether the file at `outputURL` exists and is playable, and treats `.userStopped` as success.

---

## 5. GIF export from the recorded .mp4

CleanShot-style defaults: **12 fps** (10–15 sane band), **max width 1000 px**, infinite loop. GIF delay resolution is 1/100 s and some decoders clamp delays < 0.02 s to 0.1 s — at 10–15 fps (0.066–0.1 s) you're safe; always write both clamped and unclamped keys.

```swift
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

func exportGIF(from videoURL: URL, to gifURL: URL, fps: Int = 12, maxWidth: CGFloat = 1000) async throws {
    let asset = AVURLAsset(url: videoURL)
    let seconds = try await asset.load(.duration).seconds        // async load, macOS 12+
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: maxWidth, height: maxWidth)  // fits within box, keeps aspect; pixels
    gen.requestedTimeToleranceBefore = .zero                     // exact frames (slower but correct pacing)
    gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: CMTimeScale(fps * 2))

    let frameCount = max(1, Int(seconds * Double(fps)))
    let times = (0..<frameCount).map { CMTime(value: CMTimeValue($0), timescale: CMTimeScale(fps)) }
    let delay = 1.0 / Double(fps)

    guard let dest = CGImageDestinationCreateWithURL(gifURL as CFURL,
            UTType.gif.identifier as CFString, frameCount, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFLoopCount: 0,                 // 0 = loop forever
        kCGImagePropertyGIFHasGlobalColorMap: true,      // one global 256-colour palette (smaller files)
    ]] as CFDictionary)
    let frameProps = [kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: delay,
        kCGImagePropertyGIFUnclampedDelayTime: delay,
    ]] as CFDictionary

    for await result in gen.images(for: times) {         // AsyncSequence, macOS 13+, in request order
        if case .success(_, let image, _) = result {     // .success(requestedTime:image:actualTime:)
            CGImageDestinationAddImage(dest, image, frameProps)
        }                                                 // silently skip .failure(requestedTime:error:) frames
    }
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}
```

- Modern APIs: `gen.images(for: [CMTime]) -> AVAssetImageGenerator.Images` (macOS 13+, element enum `case success(requestedTime: CMTime, image: CGImage, actualTime: CMTime)` / `case failure(requestedTime: CMTime, error: any Error)`, plus `try element.image` convenience) and `gen.image(at: CMTime) async throws -> (image: CGImage, actualTime: CMTime)`. `copyCGImage(at:actualTime:)` and `generateCGImagesAsynchronously(forTimes:)` are deprecated.
- **Palette control**: ImageIO quantises to 256 colours internally; the only public encode-side palette knob is `kCGImagePropertyGIFHasGlobalColorMap` (set `false` for per-frame local palettes — better colour on gradient-heavy clips, noticeably bigger files). There is no public dithering/quantiser-quality API in ImageIO; `kCGImageDestinationLossyCompressionQuality` has no documented effect on GIF (UNVERIFIED). If output quality ever disappoints, the standard fix is your own quantiser or ffmpeg-style palettegen — not ImageIO flags.
- Memory: CGImageDestination holds encoded frames until `Finalize`; ~1 min at 12 fps/1000 px is a sensible hard cap (the Apollo dev's video-to-gif gist reports the same practical limit and ~29 s encode times for 9 s of video on old hardware — do it on a background task with progress UI).

---

## 6. The system capture indicator + menu-bar stop UX

System behaviour (macOS 15 "Screen & System Audio Recording" era):
- **Purple indicator**: from macOS 15.1, whenever *any* app captures the screen a purple recording indicator appears in the menu-bar/Control Centre area; it persists even with the menu bar hidden and in fullscreen. It cannot be suppressed by the app. Clicking it reveals which app is capturing and gives the user a system-side way to stop the capture (exact menu contents vary by version — UNVERIFIED detail); if the user stops it there, your delegate gets `didStopWithError` `.userStopped` — handle per §4.
- **Orange dot** = microphone in use — appears additionally when `captureMicrophone = true`. Green dot = camera (n/a for us).
- **Permission**: System Settings → Privacy & Security → **Screen & System Audio Recording**. First use triggers the TCC prompt; grant requires app relaunch. macOS 15.0 re-confirms permission periodically (weekly in betas → monthly at release); 15.1 relaxed frequency for regularly-used apps and added the persistent indicator instead. You can't opt out (the `com.apple.developer.persistent-content-capture` entitlement is for VNC-class remote-desktop apps only). Preflight with `CGPreflightScreenCaptureAccess()`, prompt with `CGRequestScreenCaptureAccess()`.
- **TCC + swiftc**: the grant is keyed to the bundle ID and code signature. Ship a real `.app` bundle with an Info.plist (`NSMicrophoneUsageDescription` required for mic; screen recording has **no** usage-description key) and sign with a *stable* identity — re-signing ad-hoc with a changing signature resets/flakes the TCC grant between builds.

Menu-bar stop conventions (CleanShot / system screenshot toolbar style):
- While recording, swap the `NSStatusItem` icon to a stop glyph and show elapsed time; the whole item is the stop button (single click stops — no dropdown between the user and stopping). Offer Escape/global hotkey as secondary stop. The system's own convention (Cmd-Shift-5 recordings) is exactly this: a stop-square menu-bar button, `⌃⌘Esc` also stops.

```swift
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
func enterRecordingState() {
    item.button?.image = NSImage(systemSymbolName: "stop.circle.fill",
                                 accessibilityDescription: "Stop recording")
    item.button?.contentTintColor = .systemRed
    item.button?.imagePosition = .imageLeading
    item.button?.action = #selector(stopClicked); item.button?.target = self
    // 1 Hz timer -> item.button?.title = format(recordingOutput.recordedDuration)
}
```
- Drive the timer from `SCRecordingOutput.recordedDuration` (authoritative, not wall-clock) starting at `recordingOutputDidStartRecording` — capture start is async, so a wall-clock started at button-press drifts ~0.5 s.
- After stop: only restore the idle icon once `recordingOutputDidFinishRecording` fires, then show the post-capture overlay/thumbnail with the finalised file.

---

Sources: [SCRecordingOutput](https://developer.apple.com/documentation/screencapturekit/screcordingoutput) · [SCRecordingOutputConfiguration](https://developer.apple.com/documentation/screencapturekit/screcordingoutputconfiguration) · [SCRecordingOutputDelegate](https://developer.apple.com/documentation/screencapturekit/screcordingoutputdelegate) · [SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration) (+ per-property pages: [sourceRect](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect), [queueDepth](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth), [minimumFrameInterval](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval), [sampleRate](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/samplerate), [captureMicrophone](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone), [showMouseClicks](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/showmouseclicks)) · [SCStream](https://developer.apple.com/documentation/screencapturekit/scstream) · [SCStreamDelegate](https://developer.apple.com/documentation/screencapturekit/scstreamdelegate) · [SCStreamError.Code](https://developer.apple.com/documentation/screencapturekit/scstreamerror/code) (+ [userStopped](https://developer.apple.com/documentation/screencapturekit/scstreamerror/code/userstopped)) · [SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter) · [Capturing screen content in macOS (sample)](https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos) · [WWDC24 10088 — Capture HDR content with ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2024/10088/) · [macOS 15 SCK header diff (dotnet/macios wiki)](https://github.com/dotnet/macios/wiki/ScreenCaptureKit-macOS-xcode16.0-b1) · [AVAssetImageGenerator](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator) (+ [images(for:)](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/images), Images.Element) · [video-to-gif gist (christianselig)](https://gist.github.com/christianselig/50b9cd47ed9e5f7a7e580930f4c8c2b5) · [MacRumors — 15.1 permission prompt changes](https://www.macrumors.com/2024/10/07/apple-screen-recording-popup-update/) · [9to5Mac — 15.1 prompts](https://9to5mac.com/2024/10/07/macos-sequoia-screen-recording-popups/) · [SketchyBar #641 — 15.1 purple indicator](https://github.com/FelixKratz/SketchyBar/issues/641) · [Apple support HT/118449 — recording indicator](https://support.apple.com/118449) · [federicoterzi — empty excludingWindows gotcha](https://federicoterzi.com/blog/screencapturekit-failing-to-capture-the-entire-display/)