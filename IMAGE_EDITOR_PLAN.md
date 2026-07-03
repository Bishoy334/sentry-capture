# IMAGE_EDITOR_PLAN — "my own little Photoshop"

> **Status (2026-07-03):** Phases A–D, F and G are BUILT (see git log from
> `1eccf71` onward): subject lift/remove-bg, adjustments inspector +
> effects/curves/watermark, export dialog + paste/convert, rotate/flip,
> magnifier callout, video crop/frame-grab/burn-in (with live preview),
> batch convert, plus Finder "Open With" for images and videos with
> save-in-place. Phase E (heal/clone) is NOT built. Phase G's ML upscale is
> an OPEN GATE — owner hasn't approved bundling a Core ML model; Lanczos
> resize in the export sheet covers upscaling until then. GIF optimisation
> (Phase F tail) also remains.

The brief, verbatim from the owner: *"I want this to also be a very good image
editor — things like splicing objects, automatic png, image conversion. It
should handle anything related to screenshots, images, videos, annotation.
My own little photoshop."*

This plan is the execution handoff (same role ROUND2_PLAN.md played). It was
built from two research passes on 2026-07-03:

- **`docs/research/image-editing.md`** — SDK-verified API ground truth
  (MacOSX26.5 headers, snippets typecheck at `-target arm64-apple-macos15.0`,
  ImageIO format lists enumerated at runtime). Read it BEFORE writing any
  Vision/CoreImage/AVFoundation code; section numbers below refer to it.
- Product research across Pixelmator Pro / Photomator / Shottr / CleanShot /
  Xnip / Preview / Affinity — distilled into the priorities and anti-scope
  here. The competitive fact: no screenshot tool has crossed into the
  lightweight-editor territory that Apple's frameworks now make cheap.

## The frame (read this twice)

Screenshot-first personal tool. The winning features are **fast,
destructive-by-default, one-shot transforms** — "anything I'd otherwise open
Preview, Pixelmator or a random web tool for, I do here in two clicks."
Not a layers-and-masks compositing suite.

**The object model is already here.** A lifted subject is just another
floating object, exactly like a dragged-in image (`AnnotatorKind.image`,
`AnnotatorImageRef`). Lift → place → flatten. **Do not build a layers panel.**

## Invariants (violating any of these is a bug)

1. Plain `swiftc` build (`bash build.sh --run|--fast`), **no third-party
   dependencies**, macOS 15.0 target. SourceKit cross-file noise is ignorable;
   only build.sh output matters.
2. Coordinates: cross-module rects/points in global CG top-left points;
   annotator model coords are image-relative top-left points.
3. **One re-editable concept**: the `.sentryshot` project (annotations +
   background + object images). Adjustments preview live but **bake on
   export/save** — the project file must NOT grow a live adjustment stack.
   (That's the layers anti-pattern sneaking in the back door.)
4. Records evolve in place: every save routes through
   `OutputRouter.reExport` / `SentryStore.updateStillMedia`.
5. Brand: custom-drawn chrome uses `HUDStyle.accent`/`accentDeep`/`accentSoft`
   (Sentry amber); native controls keep the system accent. HUD cards come from
   `HUDStyle.card()`. No emojis in code/comments; Australian spelling.
6. Pin the working colour space once (sRGB end-to-end, one lifetime
   Metal-backed `CIContext` — research §8) or every adjustment inherits
   subtle colour shifts.
7. Shared "refine edge / feather" control for every mask feature — edge
   quality is the difference between "magic" and "cut out with scissors".

## Phases

Each phase = one round: build it whole, test, commit per block. Order is by
value-per-effort; A–C are the identity release ("little Photoshop" is TRUE
after C), D–G are the adjacencies.

### Phase A — Subject lift + background removal (the magic)

- **Lift tool** in the annotator toolbar (wand icon). Uses the Swift-native
  Vision layer (macOS 15, research §1a): `GenerateForegroundInstanceMaskRequest`,
  `instanceAtPoint` for click-to-pick, `generateMaskedImage` for the RGBA
  cut-out. Hover previews the detected subject with an animated outline
  (amber, `HUDStyle.accent`); click lifts it into a floating `.image`-style
  object (new `AnnotatorKind` case or reuse `.image` + `imageRef`). Options
  bar: *Detach as new image · Feather edge (slider) · Copy*.
- Drag-out to Finder from a lifted object (reuse QAO promise-provider
  pattern).
- **Remove Background** action button (whole-image, not a tool): full-frame
  mask inverted (research §2), base image replaced with alpha version,
  checkerboard already renders for transparent margins. Options after:
  *Refine edge · Replace with colour/gradient* (hands off to the existing
  background sidebar — composition for free).
- Alpha plumbing exists: `StillCapture.hasAlpha` already forces PNG delivery.
  Set it on any export whose base has alpha.
- Splice flow to verify end-to-end: lift subject in image A → copy → open
  image B → paste as object → flatten → save.

### Phase B — Adjustments inspector

- **Right-hand inspector panel** (mirror of the left background sidebar;
  collapsible via an "Adjust" toolbar toggle). Groups: Light (exposure,
  brightness, contrast, highlights/shadows), Colour (temp, tint, saturation,
  vibrance), Detail (sharpen). Each slider gets a reset dot; master reset;
  **Auto-Enhance** button at top (`CIImage.autoAdjustmentFilters`, research §3).
- Live preview: one lifetime `CIContext` (Metal, sRGB — research §8). At v1,
  render the adjusted base into the canvas's base image path on slider change
  (debounced); if that stutters at high zoom, move the canvas to a
  Metal-layer preview later — do not prematurely build it.
- **Bake on save/export** (invariant 3): applying adjustments produces a new
  baked base image (undoable via the existing whole-state snapshot undo);
  `.sentryshot` stores the baked base like a crop does today.
- Curves/levels: NOT in this phase (Phase D) — ship the sliders first.

### Phase C — Export dialog + paste→PNG + conversion

- Replace Save As… with a real **export sheet**: left = live preview +
  estimated file size; right = Format (PNG / JPEG / HEIC / TIFF / AVIF / PDF —
  all verified writable, research §5; **WebP/JXL read-only on this SDK — do
  not offer them for export**), Scale (@1x/@2x/@3x), Resize W×H with ratio
  lock (`CILanczosScaleTransform`, research §6), Quality slider for lossy,
  **"Remove metadata" checkbox DEFAULT ON** (write without the properties
  dict, research §5), destination (file / clipboard / both). Presets dropdown
  persisted in Settings ("Web @2x", "Slack JPEG"...).
- **Paste→PNG**: ⌘V into the annotator normalises any pasteboard flavour
  (PDF/TIFF/file-URL/promise) into an image object; plus a menu-bar action
  "Clean Up Clipboard Image" that round-trips the clipboard to a clean PNG
  headlessly. NSPasteboard type negotiation is the fiddly bit — enumerate
  flavours in priority order.
- History/QAO context menus gain "Convert to…" (quick single-image convert
  without opening the editor).

### Phase D — Finish the adjustments story

- **Effects presets strip** at the top of the inspector: thumbnail grid of
  tasteful Core Image stacks + `CIColorCube` LUTs (research §3). Curate few
  and good — the effort is taste, not code.
- **Curves + levels** as an "Advanced" expandable section (custom curve
  widget — the one custom control worth real effort; histogram behind it via
  `CIAreaHistogram`).
- **Watermark**: persistent re-editable overlay object (text or logo image)
  with opacity/position/tile in the options bar. Rides the object model and
  the `.sentryshot` file.

### Phase E — Heal (the honest version)

Research §4 hard truth: **no public inpainting API exists** (confirmed by
header enumeration; ImagePlayground is generation, not editing). Ship:
- **Heal brush v1**: lasso/brush a region → fill via patch-match from
  surrounding texture (hand-rolled exemplar fill) with a content-aware-blur
  fallback for flat screenshot regions (which is the common case — solid
  backgrounds, chrome).
- **Clone stamp** if patch-match quality disappoints (⌥-click source, paint).
- Gate any bundled Core ML inpaint model behind an explicit owner decision
  (binary size vs quality) — do not add one by default.
- Sits in the toolbar next to redact (same "hide something" cluster).

### Phase F — Video editor grows up

All in the existing trim editor, no new window (research §7):
- **Frame grab**: camera button on the filmstrip → current frame (async
  `generateCGImageAsynchronously`; the old API is deprecated) opens in the
  annotator as a still with a record of its own.
- **Crop video**: crop handles over the preview reusing the annotator crop
  UX; export via `AVMutableVideoComposition` renderSize + transform. Rotate
  button rides the same composition.
- **Burn annotations into video**: annotate a paused frame → overlays render
  into the export via `AVVideoCompositionCoreAnimationTool` (export-only,
  never on AVPlayer; Y-flip and `AVCoreAnimationBeginTimeAtZero` gotchas —
  research §7a). v1 = static overlays for the whole clip; timed overlays are
  anti-scope for now.
- **GIF optimisation**: shared-palette quantisation + frame de-dup on the
  existing GIF path, with a live size readout. Hand-rolled (ImageIO writes
  GIF but does not optimise) — budget tuning time.

### Phase G — Multipliers

- **Batch mode**: separate drop-zone window (not the editor): N files →
  saved export/adjust preset → progress list with per-file errors. Pure reuse
  of the C/B pipelines.
- **Upscale 2×/4×**: requires bundling a Core ML super-res model —
  **decision gate with the owner first** (tens of MB in the bundle). If
  approved, integrate as an export-dialog option with tiling for large inputs.

## Anti-scope (hold the line)

No layers panel. No RAW/photo-library/DAM. No brush engine or painting. No
live adjustment-stack document format. No text layout/DTP, no macro/scripting
DSL, no plugins. No perspective/warp. The appeal is "the screenshot tool that
grew just enough editor to never send you elsewhere" — Shottr and CleanShot
are loved because they stayed small; this stays small **plus** the
native-cheap magic.

## Risks to manage from day one

- **Edge quality** (A): budget the shared feather/refine control.
- **Colour management** (B): pin sRGB + one CIContext before the first slider.
- **Preview performance** (B): debounce first, Metal layer only if needed.
- **WebP expectations** (C): read yes, write no — say so in the UI copy.
- **Heal expectations** (E): market it as "remove the cursor / the
  notification", not Photoshop generative fill.

## Definition of done, per phase

Build clean via build.sh; feature exercised end-to-end on a real capture;
undo works through every new operation (whole-state snapshots); `.sentryshot`
round-trips (save → reopen → still editable); exports honour alpha and
metadata settings; no regression in the annotate→save→re-edit loop; commit
per block with the repo's single-line convention.
