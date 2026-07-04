# Sentry Capture

Native macOS screenshot + screen-recording app, part of the Sentry ecosystem. Replaces the built-in macOS screenshot tools. Menu-bar only, no cloud, no Electron.

- Area / window / fullscreen capture (ScreenCaptureKit)
- Quick-access overlay: floating post-capture thumbnail — copy, save, annotate, pin, drag out
- Annotator: arrows, shapes, text, highlighter, counter badges, blur/pixelate, crop, undo
- Recording: region/window to MP4, or GIF
- Scrolling capture: stitched tall screenshots (Vision image registration)
- Pin to screen, OCR copy-text, configurable global hotkeys (no Accessibility permission needed)

## Build & run

```bash
bash build.sh --run          # release build → ~/Applications/Sentry Capture.app
bash build.sh --fast --run   # -Onone, quicker compile for dev
```

Plain `swiftc` over `src/` — no Xcode project, no dependencies. Requires macOS 15+.

First run: grant Screen Recording under System Settings → Privacy & Security. The grant is tied to the code signature; with ad-hoc signing a rebuild may occasionally re-prompt.

## Layout

```
src/
  main.swift              NSApplication bootstrap (LSUIElement accessory app)
  AppDelegate.swift       Status item, menu, hotkey dispatch — the wiring hub
  Types.swift             StillCapture/VideoCapture, Coords (CG↔AppKit flip), Hotkey
  Settings.swift          UserDefaults-backed ObservableObject
  HotkeyManager.swift     Carbon RegisterEventHotKey wrapper
  CaptureEngine.swift     ScreenCaptureKit stills; all rects in global CG top-left points
  OutputRouter.swift      Sound/clipboard/save/QAO pipeline, recents, filenames
  SelectionOverlay.swift  Crosshair region/window selection overlay
  QuickAccessOverlay.swift  Floating thumbnail stack
  PinWindow.swift         Pin screenshot to screen
  Recorder.swift          SCStream recording → MP4
  GIFExporter.swift       MP4 → animated GIF
  ScrollingCapture.swift  Frame capture + Vision stitch
  Preferences.swift       SwiftUI settings window
  OCR.swift / Toast.swift Vision text recognition; transient HUD
  Annotator/              Canvas, tools, models
```
