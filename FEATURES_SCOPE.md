# Sentry Capture — Full Feature & Improvement Scope

A wide-net backlog of everything worth doing: new features, enrichments of what exists, UI cleanups, and robustness. Not a build order — a menu to prioritize from and pull into Fable briefs. `ROUND2_PLAN.md` is the focused hand-off; this is the superset it draws from.

**Legend** — Type: 🆕 new · ➕ enrich existing · 🎨 UI/UX cleanup · 🛠 robustness/tech-debt. Effort: **S** (hours) · **M** (a day-ish) · **L** (multi-day/subsystem). Where useful, code anchors reference the current implementation.

---

## 1. Capture modes & selection UX
*Current: area / window / fullscreen / scrolling via ScreenCaptureKit (`CaptureEngine.swift`), selection in `SelectionOverlay.swift`.*

- 🆕 **All-in-One mode** — one hotkey → overlay to pick area/window/fullscreen, start recording, or OCR, with remembered last-selection. **L**
- 🆕 **Self-timer / delayed capture** — countdown before firing (for menus, hover states). **S**
- 🆕 **Freeze-screen capture** — freeze the display while selecting so you can capture menus, tooltips, animations, drag states. High real-world value. **M**
- ➕ **Magnifier loupe + pixel readout** during area select — zoomed crosshair with x/y + the pixel color under cursor. `SelectionOverlay.swift`. **M**
- ➕ **Live dimensions + size entry** — show W×H while dragging; type exact dimensions; lock aspect ratio (Shift already does square). **S–M**
- ➕ **Repeat-last-region** is in (`lastRect`); surface it as its own hotkey + "capture same region" menu item. **S**
- ➕ **Window capture options** — toggle shadow, transparent vs. filled background, padding, corner rounding at capture time. **M**
- 🆕 **Capture specific window *element*/region** (part of a window) with freeze. **M**
- ➕ **Multi-monitor & mixed-DPI polish** — verify selection/coords across displays with different scale factors; capture "display under mouse" vs. "all displays" (stitched). **M**
- 🆕 **Scrolling capture live preview** — show the stitched result growing as you scroll, with a manual "stop"; handle sticky headers/overlap ambiguity. Enriches `ScrollingCapture.swift`. **L**

## 2. Annotator — the big one
*Current: `Annotator/` — flat annotation model, one shared draw routine (screen+export), whole-state undo, 12 tools, left rail + options bar + bottom bar.*

### Toolbar & chrome (🎨 the headline UI ask)
- 🎨 **Move tool rail to a top toolbar**, grouped (crop/canvas · shapes · emphasis · ink · select). `AnnotatorWindow.buildRail()`. **M**
- 🎨 **Richer contextual options bar** under the toolbar — changes per tool (color, stroke, arrow style, text style, blur style), always visible near the tools. `rebuildOptionsBar`. **M**
- 🎨 **Cleaner action placement** — Copy / Save / Save As… / Pin / Send-to up top-right; keep dimensions in a tidy footer. **S**
- 🎨 **Tool tooltips + keyboard hints**, consistent iconography, dark/light parity. **S**

### Cropping (🎨 flagged pain point — it's small/fiddly today)
- ➕🎨 **Bigger, easier crop** — large grab handles, dimmed outside region, prominent when invoked (not always-on). `commitCrop()`. **M**
- ➕ **Aspect-ratio lock** (free/1:1/16:9/4:3/custom) + **edge snapping** + live dimensions. **M**
- 🆕 **Non-destructive canvas expansion** — let annotations extend past image bounds, auto-grow canvas, fill with detected/edge color. Unlocks backgrounds + off-image arrows. **L**

### Tools (➕ enrich the set toward CleanShot parity + beyond)
- ➕ **Arrow styles** — multiple incl. **curved** (today: one arrow). **M**
- ➕ **Text styles** — presets (standard/rounded/mono/outlined/boxed…), not just raw font. Persist last-used ([[live-preview-feel]] applies to size slider). **M**
- ➕ **Blur variants** — true gaussian + "secure" heavy; ensure pixelate uses randomization (non-reversible). Builds on `AnnotatorRedactRenderer`. **M**
- 🆕 **Spotlight** — darken everything except a drawn region. **M**
- 🆕 **Magnifier/zoom callout** annotation — a zoomed inset of part of the image. **M**
- ➕ **Highlighter** — make it text-line-friendly (snap to a band). **S**
- ➕ **Counter** — verify auto-increment, restyle, drag. **S**
- ➕ **Pencil** — auto-smoothing. **S**
- 🆕 **Numbered/labeled callouts** (box + leader line + text). **M**

### Object model & interaction (➕ make it feel like a real editor)
- ➕ **Full select/move/resize/duplicate/z-order** on any placed object, **multi-select + marquee**, **align/distribute**. `AnnotatorHit`. **L**
- ➕ **Snapping & smart guides** between objects and to canvas edges/center. **M**
- ➕ **Keyboard workflow** — self-designed tool shortcuts (V/A/R/O/T/L/H/B/C…), ⌘D duplicate, arrows nudge, ⌥-drag duplicate. (Don't copy CleanShot's — research showed its single-key shortcuts don't exist.) **M**
- 🆕 **Eyedropper / color picker** for annotation colors, with recent-colors + hex entry. **S–M**
- 🆕 **Image adjustments** — rotate 90°, flip, straighten. **M**
- 🆕 **Re-editable `.sentryshot` documents** — serialize the (flat, Equatable) annotation array + base image so captures reopen for editing. DECIDED in ROUND2. **M**
- 🛠 **Live-preview throttling** — stroke/blur/text-size sliders should **throttle (never debounce)** live redraws; **Reset clears the whole pending look**. Per [[live-preview-feel]]. **S**

### Backgrounds / "make it pretty" (🆕 sharing polish)
- 🆕 **Background mode** — gradient/solid/image behind a padded, shadowed, rounded screenshot; presets; auto-balance padding. Reuses canvas-expansion. **L**

## 3. Recording
*Current: `Recorder.swift` — SCStream→h264 mp4, GIF post-convert, control strip, countdown, border.*

- 🆕 **Click highlight** — visualize mouse clicks (color/size/style/animation). **M**
- 🆕 **Keystroke display** — on-screen overlay of keys pressed (all vs. command-only, theme, position). **M**
- 🆕 **Camera/webcam overlay** — position/size/shape/fullscreen. **L**
- 🆕 **Hide desktop icons / declutter** during recording. **S**
- 🆕 **Auto-DND / Focus** during recording. **S**
- ➕ **Cursor options** — show/hide, highlight ring, size. **S**
- 🆕 **Pause/resume** recording. **M**
- ➕ **Post-record editor** — trim (has some), plus resolution/quality reduction, mute/volume, stereo→mono, playback preview. `GIFExporter`/`Recorder`. **M–L**
- ➕ **GIF quality controls** — fps/dither/palette/loop; current cap is 50fps/≤120s. **M**
- 🆕 **Adjust recording region after start** / follow-window recording. **M**

## 4. OCR & smart capture
*Current: `OCR.swift`, Vision accurate path, copy to clipboard.*

- 🆕 **QR / barcode decode** with actions (open URL, copy). **S**
- ➕ **Multi-language recognition** toggle. **S**
- 🆕 **Detected-data actions** — recognize links/emails/phones/addresses in a capture and offer copy/open. **M**
- 🆕 **Copy text with layout** (preserve line/columns) / copy as Markdown. **M**
- 🆕 **"Capture text" mode** — select a region → text straight to clipboard, no image saved (CleanShot's text-capture). **S–M**

## 5. Quick Access Overlay (QAO)
*Current: `QuickAccessOverlay.swift` — ≤5 cards, copy/save/annotate/pin/copy-text/trash/drag-out.*

- ➕ **File info / metadata** on the card (dimensions, size, type). **S**
- 🆕 **Restore recently-closed overlay**. **S**
- ➕ **Resize + reposition + auto-close timing config**; remember per-user. **M**
- 🆕 **"Send to…" affordance** on cards (Sentry apps / share sheet). **M**
- ➕ **Swipe-to-dismiss gesture**; multi-display placement polish. **S–M**

## 6. Pins (floating screenshots)
*Current: `PinWindow.swift` — always-on-top, aspect-locked resize, scroll-to-fade.*

- 🆕 **Opacity control** + **lock/click-through mode** (interact with app beneath). **M**
- ➕ **Arrow-key pixel positioning** + snap to screen edges. **S**
- 🆕 **Pin from any capture/QAO/annotator** consistently; multiple pins management. **S**
- 🆕 **Pin as always-on-top note** (add quick annotation on the pin). **M**

## 7. Output, export & destinations
*Current: `OutputRouter.swift` — the single deliver() pipeline; PNG/JPG, ~/Desktop, clipboard multi-rep.*

- 🆕 **More formats** — WebP, HEIC, PDF, TIFF; per-type default. **M**
- ➕ **Filename templates** — tokens (date/app/window/counter/dimensions). Enriches `nextFileName`. **S–M**
- ➕ **Per-capture-type destinations & quality** (screenshots vs. recordings vs. scrolling). **M**
- 🆕 **Save presets** — quick-switch export configs. **S**
- ➕ **Retina/scale export options** — 1×/2×/actual; already downscales, expose it. **S**
- 🛠 **Unify re-export through `deliver()`** — annotator/QAO/pin saves currently bypass it, so sounds/recents/(future) integration hooks don't fire. Add one shared "capture finalized" helper. **M** *(foundational — do early)*

## 8. History / recents
*Current: in-memory `[URL]` capped at 10, menu-only, lost on relaunch.*

- 🆕 **Persistent capture history panel** — grid, thumbnails, survive relaunch, ~1-month retention. **L**
- ➕ **Filter by type** (screenshot/recording/scroll/OCR), delete, restore/re-open, **re-edit** (with `.sentryshot`). **M**
- 🆕 **Search history by OCR text** — index recognized text so image captures are text-searchable. **M**
- 🆕 **Tags / notes** on captures. **M**

## 9. Dev / design tools (Shottr-class — great fit for a power user)
- 🆕 **Screen ruler / measure** — arrow keys extend, live px readout. **M**
- 🆕 **Pixel color picker** — loupe, copy hex/RGB/**OKLCH**. **M**
- 🆕 **Contrast checker** (WCAG / APCA) on a selected region. **S** (once color picker exists)
- 🆕 **Pixel grid / zoom inspector** at high magnification. **S–M**

## 10. Preferences, onboarding & app shell
*Current: `Preferences.swift` SwiftUI 4-tab; `Settings.swift` UserDefaults; menu-bar `LSUIElement`.*

- 🎨 **Preferences redesign** — per-capture-type sections, previews of settings, richer shortcut UI. **M**
- 🆕 **First-run onboarding + permissions flow** — Screen Recording / Accessibility / Full Disk with clear guidance (permissions are a common failure point). **M**
- 🆕 **In-app update mechanism** (or at least version check). **M**
- 🎨 **Menu-bar menu cleanup** — grouping, recents submenu polish (`AppDelegate.menuNeedsUpdate`). **S**
- 🛠 **Settings persistence ergonomics** — today every field is hand-mirrored in `init` + `persist()` + the SwiftUI panes; a property-wrapper/`@AppStorage`-style approach removes the triple-edit tax. **M**
- ➕ **Richer hotkey set** — per-mode hotkeys, all actions bindable; conflict detection. `HotkeyManager.swift`. **S–M**
- 🎨 **Sound & HUD/toast consistency** — unify `Toast.swift` styling, optional per-action sounds. **S**

## 11. Robustness / tech-debt (🛠)
- 🛠 **`AnnotatorCanvas.mouseUp` redact-redraw** repeats across 3 near-identical branches and reads `drag` post-resolution — refactor to one path. `AnnotatorCanvas.swift:352`. **S**
- 🛠 **deliver() bypass** (see 7) — the one hook everything should route through. **M**
- 🛠 **Undo granularity** — whole-state snapshots are simple but heavy for large images; consider per-op undo if it bites. **M** *(only if measured)*
- 🛠 **Own-UI exclusion** must survive all new capture paths (recent fix — don't regress). **—**
- 🛠 **Live-preview throttling** across all slider-driven previews ([[live-preview-feel]]). **S**

## 12. Integration hooks (light — full design lives in ROUND2 Part C)
- 🆕 **Per-capture manifest + `~/Sentry/captures/` write** (DECIDED root). **M**
- 🆕 **`sentry-capture://` URL scheme** (validated action set). **M**
- 🆕 **"Send to Sentry" destination menu** driven by the capability registry. **M**
- 🆕 **Local command service / MCP** exposure — only once the launcher exists. **L** *(defer)*

---

## How to read this for prioritizing
- **Biggest visible payoff:** §2 annotator (top toolbar + cropping + tool enrichment + object model) — this is the "feels bare" complaint.
- **Cheap foundational win, do early:** §7 `deliver()` unification — unblocks integration, sounds, recents for every path.
- **High-value new capture:** All-in-One, freeze-screen, persistent history (with OCR search).
- **Differentiators vs. CleanShot:** Shottr dev tools (§9), OCR smart-actions (§4), and the Sentry integration (§12).
- **Defer:** camera overlay, full video editor, local command service, cloud anything.
