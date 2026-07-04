# Sentry Capture — Round 2 Plan

A brief for the next Fable session. Two goals:

1. **Level up the app** — richer annotation editor (top toolbar, accessible cropping), plus the best missing CleanShot X / Shottr features.
2. **Make it a citizen of the Sentry ecosystem** — a standardized, local-first integration layer so captures can flow into the broader Sentry apps (calendar, finance, screen-time, HA, health, journal, password manager) and the planned Raycast-style launcher + local LLM.

This is a **direction** doc, not a line-by-line spec. Treat every feature idea below as an invitation to do the best version, not a checklist to satisfy minimally — **go maximal**. The only things that are genuinely fixed are the four architectural invariants in §0 (they're what makes the app good); everything else is yours to design, reorder, improve, or exceed. If you see a better feature than what's listed, build it. The full CleanShot X feature catalog is in the Appendix so you have the complete menu — pull from all of it.

---

## 0. What already exists (don't rebuild it)

Sentry Capture is ~7k lines of native Swift/AppKit, `swiftc`-built (no Xcode, no deps), menu-bar `LSUIElement` app, macOS 15+. It's in good shape. The architecture already has the right bones:

- **Capture** — all still capture is centralized in `CaptureEngine.swift` via ScreenCaptureKit (`SCScreenshotManager`). Area / window / fullscreen / scrolling all work. Own-UI exclusion by PID filtering is in place.
- **After-capture pipeline** — `OutputRouter.deliver()` is the single choke point every capture flows through (sound → clipboard → save → QAO → recents).
- **Annotator** — `Annotator/` has a genuinely clean design: one flat `AnnotatorAnnotation` struct in image-point coords, a **single shared `AnnotatorRender.draw` routine used for both screen and export** (WYSIWYG by construction), whole-state-snapshot undo, 12 tools already (select, crop, arrow, line, rect, filledRect, ellipse, draw, highlighter, text, counter, redact).
- **Recording** — `Recorder.swift`, native SCStream → h264 mp4, GIF via post-convert. Phase machine + single terminal path.
- **The rest** — Vision OCR, QAO with drag-out via file promises, pins, Carbon hotkeys, SwiftUI preferences.

**The four invariants — preserve these, they're why the app is good (everything else is open):**
- The `Coords` single-flip discipline / "everything is global CG top-left points" invariant (`Types.swift`). Don't scatter coordinate flips.
- The "one draw routine for screen + export" annotator design. New tools plug into `AnnotatorRender.draw` + `composite`, not a parallel export path.
- `OutputRouter.deliver()` as the one after-capture pipeline.
- No third-party dependencies; native frameworks only; keep `build.sh` working.

**Known seam to fix while you're in there:** annotator / QAO / pin re-saves currently call `save`/`saveAs`/`copyToClipboard` directly and **bypass `deliver()`**, so after-capture side effects (and, in round 2, the Sentry integration hook) silently don't fire for those paths. Introduce one shared "capture finalized" helper that `deliver()` *and* every re-export path call. This matters a lot for Part C.

---

## PART A — Annotation editor overhaul (the #1 ask)

The editor works but feels bare. Target: it should feel like the best part of the app.

### A1. Toolbar to the top
Move the tool rail from the left vertical strip (`AnnotatorWindow.buildRail()`) to a **horizontal top toolbar**. This is the primary visual ask. While you're restructuring the chrome:
- Group logically: **[capture-level: crop, canvas/background] · [shapes: arrow, line, rect, ellipse] · [emphasis: highlighter, blur, pixelate, spotlight, counter] · [ink: pencil, text] · [select]**.
- The **contextual options bar** (color, stroke width, arrow style, text style, redact style) should sit directly under the top toolbar and change with the active tool. It already exists (`rebuildOptionsBar`) — make it richer and always visible near the tools, not detached.
- Keep Copy / Save / Save As… + the dimensions label, but consider a cleaner footer or moving primary actions (Copy, Save, **Send to Sentry**, Pin) to the top-right. Your call on exact layout — make it feel like a real editor, not a debug panel.

### A2. Cropping — make it bigger, easier, more accessible
The problem today: when you go to crop, the affordance is small and fiddly. It doesn't need to be always-visible — it needs to be **prominent and easy to grab when you invoke it**. Ideas (Fable's call on execution):
- Big, obvious crop handles + a dimmed outside-region while cropping, so the crop region reads clearly and the grab targets are large.
- **Aspect-ratio locking** (free, 1:1, 16:9, 4:3, custom) and **edge snapping**, with live dimensions while dragging.
- **Non-destructive canvas expansion**: let annotations extend beyond the image bounds and auto-grow the canvas (arrow starting off-image, callouts in the margin), filling new area with a detected/edge background color or a chosen background. This also feeds A5.

### A3. Richer tool set (fill the gaps vs CleanShot X)
You already have most primitives. Add/upgrade toward parity:
- **Arrow styles** — multiple styles incl. a **curved arrow** (CleanShot ships 4). Currently one arrow.
- **Text styles** — CleanShot offers 7 presets (Standard, Rounded, Monospaced, Outlined, Boxed, Round-Boxed, Monospaced-Boxed). Add a small style picker rather than raw font controls only. Persist last-used (the codebase already persists text-edit style — extend it).
- **Blur variants** — "secure" (heavy) vs "smooth"; you have redact/pixelate, add a true gaussian blur option. Pixelate should use randomization so it can't be reversed.
- **Spotlight** — darken everything except a drawn region. New tool; renders as a dimming overlay in `AnnotatorRender.draw`.
- **Highlighter** — you have it; make it text-line-friendly (semi-transparent, snaps to a horizontal band).
- **Counter** — you have it; ensure auto-increment + draggable + restyle-able.
- **Backgrounds & padding** (see A5).

### A4. Object model & interaction polish
- **Full select/move/resize/duplicate/z-order** on any placed annotation, with multi-select. `AnnotatorHit` + the flat model already support hit-testing — extend to marquee-select and group ops.
- **Keyboard workflow — design your own, don't copy CleanShot's.** (Research finding: CleanShot's rumored single-key tool shortcuts don't actually exist as documented — don't cargo-cult them.) Pick a coherent scheme: single-key tool switching (V/A/R/O/T/L/H/B/C…), ⌘D duplicate, arrows to nudge, ⌥-drag to duplicate, ⌘Z/⌘⇧Z already work. Make it discoverable (tooltips with the key).
- **Re-editable documents (DECIDED — build the full version):** annotations are currently in-memory only — closing discards editable state. Ship a `.sentryshot` project format: flat JSON of the annotation array (they're already a flat, `Equatable`, image-point-coord struct — trivial to `Codable`) + a reference/embed of the base image. Any capture can be reopened and re-edited from the recents panel (Part B). This is also the richest payload for Part C — the integration manifest references it.

### A5. Backgrounds / "make it pretty" mode
CleanShot's background tool (gradient/solid/image behind a padded, shadowed screenshot) is a signature feature for sharing. Add a background/padding mode: padding slider, corner radius, shadow, and a few gradient/solid presets. Reuse the canvas-expansion machinery from A2. Keep it optional/non-destructive.

---

## PART B — Capture & feature additions (pick the high-value ones)

Prioritized. Top group is worth doing; lower group is nice-to-have.

**High value:**
- **All-in-One capture mode** — one hotkey → a single overlay where you can choose area/window/fullscreen, start a recording, or start OCR, with remembered last-selection and size/aspect entry. This is CleanShot's most-loved capture affordance and maps cleanly onto your existing `SelectionController`.
- **Freeze screen** — freeze the display while selecting so you can capture menus/hover/animation states. Big real-world win; ScreenCaptureKit gives you the frame to freeze on.
- **Magnifier + crosshair polish** on the selection overlay — a pixel-loupe with a readout while dragging. `SelectionOverlay.swift` is the place.
- **Persistent recents panel** — recents is currently in-memory, capped at 10, menu-only, lost on relaunch. Build a real, persistent capture history (grid panel, filter by type, restore/re-open/re-edit, delete). This also pairs with the re-editable documents in A4 and is a natural browse surface for the Sentry integration.
- **Self-timer** capture mode.

**Design/dev tools (Shottr's genuine edge over CleanShot — great fit for a personal power-user tool):**
- **Screen ruler / measure** (arrow keys to extend, live px readout).
- **Pixel color picker** — loupe + copy hex/RGB, ideally OKLCH; press a key to copy color under cursor.
- **Contrast checker** (WCAG / APCA) on a selected region — niche but cheap once you have the color picker.

**Recording upgrades (lower priority):**
- Click highlight (visualize mouse clicks), keystroke overlay, hide-desktop-icons, camera/webcam overlay, auto-DND during recording. Do these only if the editor + integration work lands first.

One thing to keep true: all new capture should keep excluding Sentry Capture's own UI (the existing PID-filter via `SCContentFilter`) — don't regress own-window exclusion, that was a real fix (see recent commits).

---

## PART C — The Sentry Integration Schema (the strategic core)

This is the part that outlives the app. The goal: **one standardized contract** that any Sentry app (present or future) implements, so Sentry Capture is the first proof of it. Design it as a reusable spec, not a one-off hack for captures.

### C1. Principles (from local-first research)
- **Local disk is the authoritative copy.** Every capture is a real file + a sidecar manifest on disk. No feature should depend on a server. (Future home-server sync is a *secondary* copy — explicitly out of scope for now, but the schema should be sync-friendly: stable IDs, no assumptions about a single machine.)
- **Open, inspectable format.** JSON manifests + media sidecars. Any Sentry app — or a shell script, or the local LLM — can read a capture without a proprietary SDK. (Local storage alone ≠ interoperability; the *open schema* is what delivers it.)
- **Fixed, registered message set for anything active.** Follow Raycast's IPC model: a small, explicit set of allowed commands, not arbitrary RPC into the app.

### C2. The on-disk capture record (the data contract)
Every finalized capture writes under **`~/Sentry/captures/`** (DECIDED — the ecosystem root; other Sentry apps get siblings like `~/Sentry/finance/`, `~/Sentry/journal/`. Change the default `saveDirectory` in `Settings.swift`/`OutputRouter` accordingly, but keep "also copy to clipboard" and let the user override the folder):
```
~/Sentry/captures/<id>/
  capture.png|mp4|gif          # the media
  capture.sentryshot           # (optional) re-editable annotation project (Part A4)
  manifest.json                # the standardized record
```
`manifest.json` — draft schema (refine it, but keep it flat and versioned):
```jsonc
{
  "schema": "sentry.capture/v1",
  "id": "uuid",                       // stable, sync-safe
  "app": "sentry.capture",
  "kind": "screenshot|window|scroll|recording|ocr",
  "createdAt": "ISO-8601",
  "media": { "path": "capture.png", "type": "image/png",
             "width": 2400, "height": 1898, "bytes": 123456 },
  "source": { "appBundleId": "com.google.Chrome",   // captured app, if known
              "windowTitle": "About Our Returns…",
              "url": null, "display": 1 },
  "ocrText": "…",                     // if OCR ran / on demand
  "annotations": { "count": 3, "project": "capture.sentryshot" },
  "tags": [], "notes": null,
  "hash": "sha256:…"
}
```
This manifest is the thing every other Sentry app consumes. Design the shared envelope (`schema`, `id`, `app`, `kind`, `createdAt`, `source`, `hash`, `tags`) as a **generic Sentry record** so finance/journal/health records reuse the same top-level shape — that's the "nice schema for my other apps" the brief asked for. Capture-specific fields (`media`, `ocrText`, `annotations`) live under a typed body. Put the schema definition in a shared doc (`SENTRY_SCHEMA.md`) so the other apps adopt it verbatim.

**Where this hooks in code:** the shared "capture finalized" helper from §0 (the one `deliver()` and all re-export paths call) writes the manifest. One place, fires for every capture including annotator/QAO/pin re-saves.

### C3. Transports (how other apps get the capture)
Offer a layered set — cheapest first, so the ecosystem can grow into it:

1. **Manifest folder (passive, zero-coupling).** Just writing C2 is already an integration: any app can watch `~/Sentry/captures/` (FSEvents) and react. The local LLM / launcher can grep OCR text. Do this first — it's almost free and immediately useful.
2. **URL scheme (active hand-off, both directions).** Register `sentry-capture://` (and consume a shared `sentry://` space). Actions like `sentry-capture://capture?mode=area&then=send:journal`, `sentry-capture://open?id=…`, and outbound `sentry://finance/attach?capture=<id>`. This is the standard, simplest macOS IPC and what CleanShot itself exposes. **HARD CONSTRAINT:** validate/whitelist actions — a URL scheme is an input trust boundary; only accept a fixed action set, never eval arbitrary params.
3. **Local command service (active, for the launcher + LLM).** A small local JSON-RPC service over a Unix domain socket (or a localhost port bound to loopback), exposing a **fixed registered message set** — `capture(mode)`, `listRecents(filter)`, `getCapture(id)`, `ocr(id)`, `sendTo(app, id)`. Model it on Raycast's extension IPC (JSON-RPC over fd streams, fixed message set, no arbitrary calls). This is what the Raycast-style Sentry launcher talks to for "⌘Space → screenshot area → send to journal," and what the local LLM calls to pull a capture + its OCR text as context. Consider exposing it as an **MCP server** too, so the local LLM can use it as a tool natively — same fixed command set, standard protocol. (Keep it a fixed, whitelisted command set — a local service is a trust boundary; never eval arbitrary calls.)

Guidance: **ship 1 now, 2 next, 3 when the launcher exists.** Don't build the socket service before there's a client for it.

### C4. "Send to Sentry" as a UI primitive
- A **destination registry**: Sentry apps advertise themselves (a small `~/Sentry/apps/*.json` capability file: name, icon, url-scheme, accepted kinds). Sentry Capture reads it to populate a **"Send to…"** menu on QAO cards, pin context menus, the annotator top-right, and a hotkey action.
- New `HotkeyAction` cases + `AppDelegate.dispatch` branches for "capture → send to <app>" (the dispatch/hotkey/prefs system already iterates `allCases`, so this extends cleanly).
- Sending = write the manifest (already done) + fire the target's URL scheme with the capture `id`. That's the whole contract.

---

## PART D — Sequencing for the week

A *suggested* order (reorder freely — the point is each block is independently shippable, not that this sequence is sacred):

1. **Editor overhaul (Part A)** — top toolbar, accessible cropping, richer tools, backgrounds. Highest visible payoff, most-requested.
2. **The `deliver()` unification + manifest writer (§0 fix + C2)** — small, unblocks everything in C. Do it early even though C's UI comes later.
3. **All-in-One + freeze + persistent recents panel (Part B high-value)**.
4. **Integration transport 1 (manifest folder) + URL scheme + "Send to Sentry" menu (C3.1, C3.2, C4)** — the ecosystem contract, usable immediately.
5. **Shottr-style dev tools + recording upgrades (Part B lower)** — if time remains.
6. **Local command service / MCP (C3.3)** — only if the launcher work starts this week; otherwise leave the seam and ship later.

Leave the socket service and cloud/home-server sync as documented seams, not built code, until there's a client. (Cloud is explicitly deferred per the brief.)

---

## Notes for Fable (latitude)
- The tool groupings, exact toolbar layout, keyboard scheme, background presets, and manifest field names are **yours to improve** — the schema above is a starting contract, not gospel; if you design a cleaner envelope, update `SENTRY_SCHEMA.md` and keep it consistent.
- Bias to native frameworks (ScreenCaptureKit `SCScreenshotManager`, Vision `VNRecognizeTextRequest`, Core Image for blur, PencilKit only if it genuinely beats the current freehand). No new dependencies.
- Keep the app menu-bar-only, keep `build.sh` green, keep the coordinate discipline. Everything else, make it great.

---

## Appendix — Complete CleanShot X feature catalog (the full menu)

Every feature CleanShot X ships, so nothing's left off the table. Status vs. Sentry Capture today: **✅ have · 🟡 partial · ❌ missing**. Aim for parity or better on everything not marked deferred; if a feature sparks a better idea, build the better idea.

### Capture modes
- ✅ **Capture Area** — rectangular region select.
- ✅ **Capture Window** — single window; ❌ with **custom background** (desktop / solid / image), ❌ **padding**, 🟡 **shadow toggle**, ❌ transparency options.
- ✅ **Capture Fullscreen**.
- ✅ **Scrolling Capture** — stitch content beyond the viewport.
- ❌ **All-in-One** — one shortcut → any mode; ❌ size specification, ❌ aspect-ratio lock, ❌ selection memory.
- ❌ **Self-Timer** — delay before capture.
- ❌ **Freeze Screen** — freeze display to capture moving/hover/menu states.
- 🟡 **Crosshair + Magnifier** — precise positioning loupe with pixel readout during select.
- (skip PixelSnap-style external measurement integration; the Shottr ruler in Part B covers measuring.)

### Annotation & markup tools
- ✅ **Crop** — 🟡 make it prominent (A2), ❌ aspect-ratio spec, ❌ edge snapping.
- 🟡 **Arrow** — have one; ❌ 4 styles including **curved**.
- ✅ **Rectangle** & ✅ **Filled Rectangle**.
- ✅ **Ellipse**.
- ✅ **Line**.
- 🟡 **Pixelate** — have redact; ❌ ensure **randomized** (non-reversible).
- 🟡 **Blur** — ❌ add true gaussian; ❌ **secure vs smooth** variants.
- ❌ **Spotlight** — darken everything except the drawn region.
- ✅ **Counter** — numbered step markers (verify auto-increment + restyle).
- ✅ **Pencil** — freehand; 🟡 add auto-smoothing.
- ✅ **Highlighter** — 🟡 make it text-line-friendly.
- 🟡 **Text** — have it; ❌ **7 predefined styles** (Standard, Rounded, Monospaced, Outlined, Boxed, Round-Boxed, Monospaced-Boxed).
- ❌ **Multi-image combination** — drag additional screenshots into one composition (canvas auto-expands).
- ❌ **Editable project files** — re-openable annotated documents (this is our `.sentryshot`, A4 — DECIDED).

### Background tool (the "make it pretty" mode, A5)
- ❌ Pre-designed backgrounds (gradients/solids/images), ❌ custom upload, ❌ alignment options, ❌ **auto-balance** padding, ❌ aspect-ratio adjustment, ❌ corner radius + shadow.

### Screen recording
- ✅ **MP4 (h264)** and ✅ **GIF**.
- 🟡 **Quality / FPS / resolution** controls.
- 🟡 **Microphone** and 🟡 **system/computer audio** capture.
- ❌ **Do-Not-Disturb auto-enable** during recording.
- 🟡 **Cursor show/hide**.
- ✅ **Menu-bar timer**.
- ❌ **Hide desktop icons / declutter** during recording.
- ❌ **Click highlight** — visualize clicks (color/size/style/animation).
- ❌ **Keystroke display** — on-screen key overlay (position/size/theme, all-keys vs command-only).
- ❌ **Camera/webcam overlay** — position/size/shape/fullscreen.

### Video editor
- 🟡 **Trim**; ❌ post-hoc **quality/resolution reduction**, ❌ stereo→mono, ❌ **playback preview**, ❌ volume/mute.

### Quick Access Overlay (QAO)
- ✅ Instant post-capture card, ✅ copy, ✅ save, ✅ open annotator, ✅ pin, ✅ copy-text, ✅ trash, ✅ **drag-and-drop out** (file promises).
- ❌ File-info/metadata display, ❌ restore recently-closed overlay, 🟡 reposition, ❌ size adjustment, ❌ auto-close timing config, ❌ swipe-gesture controls. (These are polish — pick what's worth it.)

### Floating screenshots (Pins)
- ✅ Pin above all windows, ✅ always-on-top, 🟡 size, ❌ **opacity control**, ❌ **arrow-key pixel positioning**, ❌ **lock mode** (click through to app beneath).

### Text recognition (OCR)
- ✅ On-device (Vision), ✅ auto-copy to clipboard. ❌ QR-code decode (Shottr has it — easy add), ❌ multi-language toggle.

### Capture history
- 🟡 **Recents** — currently in-memory, menu-only, lost on relaunch. ❌ persistent panel, ❌ filter by type, ❌ selective delete, ❌ restore/re-open, ❌ ~1-month retention. (Part B high-value — build the real thing.)

### Cloud & sharing — **DEFERRED** (future Sentry home-server sync)
- Screenshot/video upload, shareable links, self-destruct timers, password protection, tags, custom domains, teams. Not now; keep the schema sync-friendly so it slots in later.

### Customization & polish
- 🟡 Highly configurable settings, ✅ dark/light adaptive, ✅ native macOS design. Extend preferences to cover every new toggle above.

### Beyond CleanShot — Sentry's own edge (don't just clone, exceed)
- **Shottr-class dev tools**: screen ruler, pixel color picker (copy hex/OKLCH), contrast checker (WCAG/APCA).
- **The Sentry integration layer** (Part C) — this is the thing CleanShot fundamentally can't do: captures as first-class, locally-owned records that flow into your whole ecosystem + local LLM. This is where Fable should be most ambitious.
