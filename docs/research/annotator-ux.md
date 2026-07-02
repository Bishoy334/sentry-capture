# Sentry Capture cheat-sheet — CleanShot X UX inventory + AppKit annotator architecture

Verification basis: cleanshot.com (features page, homepage, official changelog, official URL-scheme docs `cleanshot.com/docs-api`), detailed third-party reviews (Podfeet, Dave Swift, Setapp, Sweet Setup, pie-menu shortcut dump). Anything not corroborated is marked **UNVERIFIED**. Third-party shortcut lists conflict with each other — treated as unreliable for *global* defaults (flagged below).

---

## TOPIC A — CleanShot X UX inventory

### A1. Area-selection overlay

- **Backdrop**: screen dims; the pending selection area renders undimmed. Menu-bar invocation or hotkey; cursor becomes crosshair.
- **Crosshair + magnifier**: full-screen crosshair lines through the cursor with a **magnifier (pixel loupe)** at the cursor. History: crosshair mode originally hold-⌘ (changelog v2.2), magnifier added to crosshair mode (v3.4); by v4 crosshair+magnifier is the default and can be disabled/configured in prefs ("show crosshair with Command key" option, v3.1). Marketing copy: "Crosshair mode", "Magnifier". Coordinates (absolute x,y) readout: **UNVERIFIED** — verified UI shows a **live W×H size label** near the selection; an x,y display is not documented anywhere I found.
- **Window highlight mode**: hovering a window highlights it and a **single click captures that window** ("click a window to record/capture it specifically"; Capture Window mode captures with transparent background / optional wallpaper+shadow behind it). Whether plain Capture Area mode also does hover-highlight-before-drag (vs only Capture Window mode): **UNVERIFIED** — safest clone: in area mode, hover highlights the window under cursor, click = capture window, drag = capture region (this matches macOS ⇧⌘4+Space semantics and all observed CleanShot behaviour).
- **Modifiers during drag** (sources: official changelog v3.5 "Move and resize recording area using arrow keys and Cmd/Shift modifiers" + third-party lists — per-key detail UNVERIFIED beyond that):
  - `Space` (hold) — move the in-progress selection without resizing. (Third-party; standard macOS pattern.)
  - `Shift` — constrain/lock aspect ratio while resizing. Aspect-ratio *presets* with locking exist in All-in-One mode (official).
  - `Option` — resize from centre (third-party, UNVERIFIED).
  - Arrow keys — nudge/resize the selection post-drag (official changelog v3.5); with ⌘/⇧ for bigger steps / resizing.
  - `Shift` held while *invoking* a capture temporarily disables the auto-applied preset (official, v4.8.4).
- **Esc/Enter**: `Esc` cancels capture (verified everywhere). `Return` confirms/captures the current selection (third-party lists; UNVERIFIED officially, but required since arrow-key nudge exists).
- **Remembering last selection**: first-class. Official URL action `cleanshot://capture-previous-area` ("Capture Previous Area" is a separate hotkey-able command); recording area is remembered via an explicit option (v3.6). Selection persists across invocations so Enter re-captures same rect.
- **Extras**: optional **Freeze screen** during selection (official features page); **self-timer** capture (delay, default 5 s, options ~2–15 s); Tab to cycle displays (third-party, UNVERIFIED); "Hide desktop icons while capturing" option.
- **All-in-One mode** (their ⇧⌘5 analogue, official `cleanshot://all-in-one`): one overlay with a floating control strip to switch between screenshot / record / scrolling / OCR etc., with aspect-ratio locking. Exact strip layout/ordering: UNVERIFIED.

### A2. Quick Access Overlay (QAO)

- **Position**: small floating thumbnail card, **default bottom-left corner**; position AND size adjustable in prefs; "show on active display" option; multi-display support (all official/review-verified).
- **Stacking**: multiple captures each get their own thumbnail; they **stack vertically in the corner** as "a small floating panel [that] holds your recent captures". Exact ordering (newest on top vs bottom): **UNVERIFIED**.
- **Hover actions**: hovering the thumbnail reveals buttons: **Copy, Save, Annotate (edit), Pin, Upload (cloud), Close**. Right-click context menu adds **Move to Trash** (v4.1) and more. A dedicated **"Drag me" grab area** lets you drag the file into any app/Finder (drag = move/dismiss; **hold ⌥ while dragging keeps it in the overlay** — official changelog-adjacent, verified via search).
- **Keyboard shortcuts while QAO focused** (official changelog v4.1): `⌘C` copy, `⌘S` save, `⌘W` close, `⌘U` upload, `⌘E` open annotate.
- **Auto-dismiss**: optional auto-close after a configurable interval (v2.3; intervals include long ones — 5 and 10 minutes added v3.9.1); default behaviour is to stay until acted on (**default value UNVERIFIED**). Swipe gesture dismisses a thumbnail (official features page "swipe gestures").
- **Clicking the thumbnail**: primary interactions are hover-buttons and drag-out; what a bare click does (nothing vs open annotate) is **UNVERIFIED** — recommend click = open annotator for the clone.
- Save behaviour configurable (save instantly vs prompt destination). QAO can be disabled entirely; a common alternative config is "after capture → open annotate directly".

### A3. Annotator ("Annotate" window)

**Complete tool list** (union of official features page + official annotate-menu shortcut dump; letters are CleanShot's actual per-tool keys from its menus via pie-menu.com):

| Tool | Key | Notes |
|---|---|---|
| Move/select | `V` | selection + drag handles |
| Crop | `K` | aspect-ratio + edge snapping (official) |
| Background | `B` | canvas padding, solid/gradient/image backgrounds, aspect presets, save as Presets (v4.5/v4.8) |
| Arrow | `A` | 4 styles incl. curved (v4.2), thickness control |
| Line | `L` | |
| Rectangle | `R` | outline |
| Filled rectangle | `F` | |
| Ellipse | `E` | |
| Draw (pencil/freehand) | `D` | auto-smoothing (official) |
| Highlighter | `M` | semi-transparent, adjustable intensity |
| Text | `T` | 7 predefined styles incl. outlined + rounded-box (official) |
| Counter (steps badge) | `C` | numbers/letters/roman, custom start incl. 0, auto-renumber |
| Redaction (pixelate/blur) | `P` | styles: Pixelate, (Secure) Blur, Black-out (v4.2/v4.6) |
| Spotlight | `H` | dims everything except a region |
| Emoji/sticker | `;` (third-party, UNVERIFIED) | |

- **Editor actions** (official menus): `⌘Z`/`⇧⌘Z` undo/redo; `⌘C` copy selected object; `⌘D` duplicate object; `⇧⌘C` copy flattened screenshot; `⌘S` save; `⇧⌘S` save as; `⌘U` upload; `⌘P` print; `⌘I` add screenshot from file; `⇧⌘I` add new screenshot (capture into canvas); increase/decrease tool size keys exist (pie-menu shows `` ` `` / `+`, likely `[`/`]`-style — exact keys UNVERIFIED).
- **Canvas**: can draw **outside the image bounds** — canvas auto-expands with transparency; **combine multiple images** by drag-drop onto canvas; **zoom** the canvas (v4.3); **Space-drag pans** the canvas (v3.9.3); saves as re-editable **CleanShot project file**.
- **Toolbar layout**: tool icons in a **vertical strip on the left edge**; per-tool options (colour palette, stroke width, style variants) appear contextually next to/above the toolbar; bottom bar carries the export actions + drag-out handle (annotate window "draggable from the bottom bar", v4.1). Exact arrangement **UNVERIFIED** — treat left-rail tools + contextual options + bottom action bar (Copy · Save · Upload, drag handle at left) as the reference layout.
- Accessibility: colour-name display for colour-blind users; all tools VoiceOver-labelled (review-verified).

### A4. Recording

Flow (review-verified, Setapp step-by-step):
1. Invoke Record Screen (hotkey/menu) → same area-selection overlay (drag region, click a window, or fullscreen); recording area can be **remembered** (v3.6); move/resize via arrow keys + ⌘/⇧ (v3.5).
2. A **control strip appears with the selection** before recording: **Video / GIF choice is made HERE, pre-record** (official: "record… as video or optimized GIF"); toggles for **microphone (device picker, incl. iPhone via Continuity), computer/system audio, webcam overlay (circle/square/vertical, resizable), show clicks, show keystrokes, timer, Do-Not-Disturb**; then a **Record** button. Toggles adjustable "on the fly" as you start (review). Exact strip placement (bottom-centre vs attached to selection): **UNVERIFIED**.
3. Optional **countdown** before start (added v4.6; length configurable; default **UNVERIFIED**, assume 3 s).
4. While recording: **menu-bar icon shows elapsed time and acts as the stop control** (v1.1 + reviews); **pause/resume** via keyboard shortcut or the controls menu (v3.8); **restart recording** (v3.9.1); auto-DND hides notifications.
5. Stop → **QAO appears with the recording**: copy/save/upload/drag, and Edit opens the **video editor** (v3.6): trim (controls positioned so they don't cover the video, v4.2), quality/resolution change, stereo→mono, volume; GIF output is encoded if GIF was chosen; converting an MP4 to GIF after the fact exists in the editor/overlay (**UNVERIFIED location**).
- Video prefs: FPS options, max resolution cap, "scale Retina" handling (records up to 4K on retina), separate vs merged audio tracks. GIF prefs separate (fps/quality).

### A5. Pin to screen ("Pin" / floating screenshots)

- Created via capture action `pin`, QAO Pin button, or `cleanshot://pin?filepath=`. Screenshot becomes a **borderless always-on-top floating window**.
- Behaviours (official changelog + reviews): drag anywhere to move; resize (adjustable size — official homepage); **two-finger scroll over it adjusts opacity** (v4.6); **Lock mode** fixes it in place (v4.3; whether it's also click-through: UNVERIFIED); right-click menu: copy, save, annotate, close, **Close All** (v4.2); `⌘W` closes; global **shortcut to hide/show all pinned screenshots** (v4.7); persists indefinitely; multiple pins allowed.
- Styling: optional rounded corners / shadow / border via prefs (Advanced tab has the pinned-screenshot checkboxes — Podfeet).

### A6. OCR — "Capture Text"

- Invoke (hotkey/menu/`cleanshot://capture-text`) → same crosshair area selection → drag over text → **on-device recognition** → **result lands on the clipboard** + confirmation notification. No window opens by default.
- Options: **keep or strip line breaks** (official URL param `linebreaks`), automatic language detection (v4.8; many languages incl. Czech/Danish/Dutch/etc. v4.8.4), **QR-code reading** built into the same tool (v4.6). "Copy text from images, videos, scanned documents" — works on anything on screen.

### A7. Default shortcuts + Preferences

**Global defaults are genuinely unverifiable** — third-party lists contradict each other (e.g. ⌘⇧5 = "window" in one, "all-in-one" in another; ⌘⇧1/2/3 = region/window/fullscreen in a third). What IS solid: CleanShot's onboarding offers to **take over the macOS shortcuts** (⇧⌘3 fullscreen, ⇧⌘4 area — requires disabling Apple's in System Settings), everything is rebindable in the Shortcuts tab, and extra bindable actions exist ("Capture Previous Area", "Open from Clipboard", "Toggle Desktop Icons", "Capture Text", "Record Screen", "All-in-One", "Open History", "Hide pinned screenshots"). For the clone: ship ⇧⌘3 / ⇧⌘4 / ⇧⌘5(all-in-one) / ⇧⌘2(OCR) / ⇧⌘6(record) as defaults and a full rebinding UI; mark parity claims accordingly. **UNVERIFIED as CleanShot's exact out-of-box set.**

**Preferences window — exact tab set (OFFICIAL, from `cleanshot://open-settings?tab=`)**: `general, wallpaper, shortcuts, quickaccess, recording, screenshots, annotate, cloud, advanced, about` (12 panels claimed on features page; the scheme lists 10 — scrolling-capture/video may be sub-panes).

Notable options per tab (review-verified unless noted):
- **General**: after-capture actions — separate for screenshots vs video (v3.2): auto-copy, auto-save, auto-open-annotate, auto-pin, auto-upload; show QAO on/off; sounds; login item.
- **Wallpaper**: background behind window captures (colour/custom image/transparent), padding, shadow.
- **Shortcuts**: every command rebindable, grouped (General / Screenshots / Screen Recording / Scrolling / OCR / QAO).
- **Quick Access**: overlay position + size, auto-close interval (incl. 5/10 min), show on active display.
- **Screenshots**: format **PNG/JPG**; **filename template** with date/time tokens, AM/PM, month formats, auto-increment counter, App Name / Window Title tokens (default pattern ≈ `CleanShot %Y-%m-%d at %H.%M.%S` → `CleanShot 2026-07-02 at 09.41.12@2x.png` — pattern UNVERIFIED exactly); save location (default Desktop — UNVERIFIED); **"Scale down Retina screenshots to 1x"**; self-timer length (2–15 s); freeze screen; 1 px border option; crosshair/magnifier toggles.
- **Recording**: countdown on/off + length; show controls on the fly; recording time in menu bar; retina scaling for video; defaults for cursor/clicks/keystrokes/DND; **Video** (fps, quality, max resolution, mic+system audio, separate audio tracks, mono) and **GIF** (fps, quality) sub-settings.
- **Annotate**: default tool behaviours, colour-name accessibility.
- **Cloud**: n/a for us (no cloud).
- **Advanced**: pinned-screenshot styling (shadow / rounded corners / border), niche toggles, extra shortcut actions.

---

## TOPIC B — Annotator implementation architecture (AppKit, macOS 15+, Swift 6.3, plain swiftc)

### B1. Canvas: single NSView + draw(_:) — recommended

**Recommendation: one canvas `NSView`, value-type annotation array, full redraw in `draw(_:)`.** At ~50 annotations a full vector redraw is well under a frame; CALayer-per-annotation buys nothing here and costs: manual `contentsScale` management per layer, duplicated hit-testing, z-order bookkeeping, and you still need a context-based draw pass for export. Keep ONE shared draw routine `draw(annotation:in ctx:)` used by both the view and the exporter → WYSIWYG export for free.

- View setup: `wantsLayer = true`; `layerContentsRedrawPolicy = .onSetNeedsDisplay`; `override var acceptsFirstResponder: Bool { true }` (needed for keyboard + undo); `override var isFlipped: Bool { true }` (top-left origin makes rect math match screenshot coords — then remember to flip for Core Image, below).
- **Model in image point coordinates**, not view coordinates: `struct Annotation: Identifiable { let id: UUID; var kind: Kind; var frame: CGRect / points: [CGPoint]; var style: Style }` — z-order = array order. Zoom/pan is a view-level transform only. Zoom: embed in `NSScrollView` with `allowsMagnification = true`, `magnification`, `setMagnification(_:centeredAt:)` — free pinch-zoom + ⌘-scroll.
- Invalidation: during drag call `setNeedsDisplay(oldBounds.union(newBounds).insetBy(dx: -handleSlop, dy: -handleSlop))`; AppKit coalesces per frame.
- **Hit-testing** (iterate `annotations.reversed()` = topmost first; test handles before bodies):
  - Lines/arrows/freehand: fatten the stroke —
    ```swift
    let fat = path.copy(strokingWithWidth: max(style.lineWidth, 12),
                        lineCap: .round, lineJoin: .round, miterLimit: 10)
    if fat.contains(point) { … }
    ```
    `CGPath.copy(strokingWithWidth:lineCap:lineJoin:miterLimit:transform:)` and `CGPath.contains(_:using:transform:)` (macOS 10.12+) — exact names verified. `NSBezierPath.cgPath` property exists **macOS 14+** (fine on 15+ target) for converting.
  - Outline rect/ellipse: same fat-stroke trick on the outline path; filled shapes: `path.contains(point, using: .winding)`; text: padded bounding rect.
- **Selection handles**: 8 for rects/ellipses/blur/text, 2 endpoints for line/arrow, none for freehand (move-only). Draw ~8 pt white squares with 1 px border; hit slop → ≥12 pt effective target. Drag state machine per mouseDown: `.drawing(new)`, `.moving(id, grabOffset)`, `.resizing(id, handle)`. Cursors via `NSTrackingArea` (`.cursorUpdate, .activeInKeyWindow, .mouseMoved`) — `NSCursor.crosshair` when a shape tool armed, arrow/resize cursors over selection.

### B2. Text annotations — overlay editor, drawn when committed

Standard pattern (what every canvas app does):
1. On text-tool click / double-click of an existing text annotation: hide the committed rendering of that annotation, add a **borderless `NSTextView`** subview at the annotation's frame (converted to view coords):
   ```swift
   let tv = NSTextView(frame: rect)
   tv.drawsBackground = false
   tv.textContainerInset = .zero
   tv.textContainer?.lineFragmentPadding = 0   // match drawn output exactly
   tv.font = style.font; tv.textColor = style.colour
   tv.delegate = self
   addSubview(tv); window?.makeFirstResponder(tv)
   ```
2. Commit on `NSTextDelegate.textDidEndEditing(_:)` (fires on click-away/Tab) and intercept keys via `NSTextViewDelegate`:
   ```swift
   func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
       if sel == #selector(cancelOperation(_:))) { cancelEditing(); return true } // Esc
       return false
   }
   ```
3. On commit: remove the text view, store an `NSAttributedString`, render in the shared draw routine with `attributed.draw(in: rect)` / `boundingRect(with:options: [.usesLineFragmentOrigin])` for sizing. Gotcha: NSStringDrawing and NSTextView layout can differ by a point or two unless inset + lineFragmentPadding are zeroed — zero both (above) and reuse the same font/paragraph style. Grow the editor live via `NSLayoutManager.usedRect(for:)` or `tv.intrinsicContentSize` on `textDidChange`.

### B3. Blur / pixelate annotations

**Layering order: base image → all redaction patches → shapes/text → selection chrome.** Redactions sample ONLY the base image (never other annotations) — that's CleanShot's behaviour, and it makes patches cacheable and drag of other shapes free.

- Setup once: `let ciContext = CIContext()` (Metal-backed by default; creation is expensive — never per-frame); `let baseCI = CIImage(cgImage: baseCGImage)` cached.
- Per redaction annotation, on geometry/style change only, render a patch and cache the `CGImage`:
  ```swift
  import CoreImage
  import CoreImage.CIFilterBuiltins   // macOS 10.15+

  // rectPx: annotation rect in PIXEL coords, bottom-left origin
  // (flip from the view's top-left: y = pixelHeight - maxYPx)
  func blurPatch(_ rectPx: CGRect, radius: Double) -> CGImage? {
      let blurred = baseCI.clampedToExtent()               // avoid edge fade
          .applyingGaussianBlur(sigma: radius)             // CIImage convenience
          .cropped(to: rectPx)
      return ciContext.createCGImage(blurred, from: rectPx)
  }
  func pixellatePatch(_ rectPx: CGRect, scale: Float) -> CGImage? {
      let f = CIFilter.pixellate()
      f.inputImage = baseCI
      f.center = .zero          // grid anchored to the image → stable while dragging
      f.scale = scale           // default 8; use >= ~16 px for real redaction
      guard let out = f.outputImage?.cropped(to: rectPx) else { return nil }
      return ciContext.createCGImage(out, from: rectPx)
  }
  ```
  (`CIFilter.pixellate()` → props `inputImage/center/scale`; `CIFilter.gaussianBlur()` → `radius: Float`; string API equivalents `CIPixellate` kCIInputScaleKey / `CIGaussianBlur` kCIInputRadiusKey.)
- **Live preview cost**: re-rendering one patch per `mouseDragged` is a few ms for screen-size rects on Apple silicon — acceptable; if it stutters, render at `scale/2` during the drag and full-res on mouseUp. Never re-render on unrelated redraws — draw the cached `CGImage` via `ctx.draw(patch, in: rectPoints)`.
- Coordinate gotchas: Core Image is pixel-space, bottom-left origin; your model is point-space (probably top-left if `isFlipped`). Convert: `rectPx = rectPoints * backingScale`, then flip Y.
- **Security**: light gaussian blur and small pixellate scales are reversible on text. Offer a "black-out" style (plain filled rect) and clamp minimum pixellate cell size (CleanShot added "Secure Blur"/black-out for this reason). For export, the patch is baked from the base image — no live filter in the output.

### B4. Undo/redo — NSUndoManager over value snapshots (recommended)

Annotations are value types, so snapshots are free. Use **NSUndoManager driving whole-array snapshots** — you get ⌘Z/⇧⌘Z routing, Edit-menu item enabling/titles, and grouping from the responder chain, without hand-rolling stacks:

```swift
func setAnnotations(_ new: [Annotation], actionName: String) {
    let old = annotations
    undoManager?.registerUndo(withTarget: self) {   // macOS 10.11+
        $0.setAnnotations(old, actionName: actionName)   // re-registers → redo works
    }
    undoManager?.setActionName(actionName)
    annotations = new
    needsDisplay = true
}
```
- Register **once per gesture**: snapshot `annotations` at `mouseDown`, mutate freely during `mouseDragged` (no undo registration), call `setAnnotations(final)` semantics at `mouseUp` by registering the *pre-drag* snapshot. NSUndoManager auto-groups per run-loop pass (`groupsByEvent`), so one gesture = one undo step.
- The view's `undoManager` comes via the responder chain — the canvas must be first responder or the window must supply one (`NSWindowDelegate windowWillReturnUndoManager` or just let NSWindow's default per-window manager work).
- A hand-rolled immutable snapshot stack works too but re-implements menu validation and event grouping for zero gain; only choose it if you later want a history-scrubber UI.

### B5. Export — composite at native pixel scale

Screenshots are `CGImage`s at backing scale (e.g. 2x, often Display P3). Model is in image **points**; base is image **pixels**.

```swift
func composite(base: CGImage, annotations: [Annotation], pointSize: CGSize) -> CGImage? {
    guard let ctx = CGContext(
        data: nil, width: base.width, height: base.height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, // keep P3 → no colour shift
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                  | CGBitmapInfo.byteOrder32Little.rawValue)              // BGRA, always supported
    else { return nil }
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
    ctx.scaleBy(x: CGFloat(base.width) / pointSize.width,
                y: CGFloat(base.height) / pointSize.height)               // now draw in points
    // if your shared draw routine assumes top-left origin, also flip:
    // ctx.translateBy(x: 0, y: pointSize.height); ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true) // 10.10+
    for a in annotations { draw(a) }        // SAME routine the canvas uses
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}
```
- Redaction patches: draw the cached full-res patch CGImages before shapes, same as on-canvas.
- **PNG write** (ImageIO):
  ```swift
  import UniformTypeIdentifiers   // macOS 11+
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, cg, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary) // 144 dpi = @2x point size in Preview
  CGImageDestinationFinalize(dest)
  ```
  Name the file `…@2x.png` like CleanShot. "Scale down Retina": redraw into a context of `pointSize` pixels instead.
- **Copy**: `NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([NSImage(cgImage: cg, size: pointSize)])`. **Save As**: `NSSavePanel` with `allowedContentTypes = [.png, .jpeg]` (macOS 11+).
- Alternative for simple cases: `NSImage(size:flipped:drawingHandler:)` (10.8+) — but it renders at the *destination* context's scale, so the explicit CGContext above is the reliable native-scale path.

### Swift 6.3 / plain-swiftc notes
- AppKit types are `@MainActor` under Swift 6 — keep canvas/model/undo on the main actor; CIContext patch renders can hop off-main but don't bother initially.
- Imports needed: `AppKit`, `CoreImage`, `CoreImage.CIFilterBuiltins`, `UniformTypeIdentifiers`. No SPM deps required for any of the above.
- All listed APIs are available well below the macOS 15 target; the only recent one is `NSBezierPath.cgPath` (macOS 14+).

---

Sources: [CleanShot X features](https://cleanshot.com/features) · [CleanShot X homepage](https://cleanshot.com/) · [Official changelog](https://cleanshot.com/changelog) · [Official URL-scheme API docs](https://cleanshot.com/docs-api) · [Podfeet review](https://www.podfeet.com/blog/2022/04/cleanshot-x/) · [Dave Swift review](https://daveswift.com/cleanshot-x/) · [Setapp tutorial](https://setapp.com/how-to/no-clutter-screen-capturing-for-mac) · [Sweet Setup](https://thesweetsetup.com/take-better-screenshots-with-cleanshot-x/) · [pie-menu shortcut dump](https://www.pie-menu.com/shortcuts/cleanshot) · [KeyScreen shortcut list (unreliable for globals)](https://keyscreenapp.com/cleanshot-x-keyboard-shortcuts) · [MakerStack review](https://makerstack.co/reviews/cleanshot-x-review/) · [iMore on QAO shortcuts](https://www.imore.com/cleanshot-x-gains-new-keyboard-shortcuts-quick-access-overlay-more)