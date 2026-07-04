# Sentry Capture — UI/UX Audit

_Deep audit across 6 surfaces (QAO, All-in-One strip, annotator chrome, annotator panels, video editor) + systemic consistency + UX-flow tracing. 7 auditors + synthesis._

## Executive summary

Sentry Capture is feature-rich but its chrome has outrun its polish: the two heaviest themes are silent data-loss on close/save (both editors tear down without a dirty check, and "Edit Recording → Save" overwrites the only copy irreversibly) and redundant/duplicated controls (the video editor layers the system player's inline transport over the app's own volume + filmstrip, producing two volume sliders and two scrubbers that disagree). Discoverability is the next tier: the QAO buries its differentiating actions (OCR, Send-to) behind an un-hinted right-click, the All-in-One strip looks broken before a region is selected with its only guidance stranded at the top of the screen, and the annotator's ~23 low-contrast monochrome glyphs are unscannable. The annotator panels have real bugs (opening a panel drifts the canvas off-center and clips it; fill swatches never show which background is active) plus a pervasive lack of numeric slider feedback. Underneath sits a consistency layer — brand-amber accent vs system-blue CTAs, ad-hoc radii/type, "100%" shown twice, Save/Save As placed three different ways — that makes the surfaces feel like separate design systems. Most fixes are small; a handful of state-invisibility and data-loss bugs are cheap and should ship first.

## Quick wins (do first — high value, S effort)

1. **Fill swatches never show the active background** (annotator-panels) — Give the selected fill swatch an accent selection ring (borderWidth 2 + HUDStyle.accent) the way EFFECTS thumbnails already do, updated in backgroundFillTapped and on rebuild so it survives reopen.  
   `src/Annotator/AnnotatorWindow.swift:908`
2. **QAO Save-then-Annotate forks a duplicate record** (qao) — After reExport, rebuild the DeliveredCapture payload with the new recordID so annotate/copyText/convert/drag key off the saved record instead of the stale nil-id still.  
   `src/QuickAccessOverlay.swift:735`
3. **Crop/Annotate/Frame-grab stay live during export** (video-editor) — Add frameButton, cropButton, and annotateButton to the controls array in setBusy so all mutating/opening actions disable while an export is in flight.  
   `src/VideoEditor.swift:579`
4. **Footer shows "100%" twice** (annotator-chrome) — Delete the standalone zoomActual button and make zoomLabel itself the clickable actual-size control wired to zoomActualTapped.  
   `src/Annotator/AnnotatorWindow.swift:514`
5. **Magnifier icon used for Reveal in Finder** (qao) — Swap 'magnifyingglass' for a Finder-reveal glyph ('folder' / 'arrow.up.forward.app') and update the tooltip; keep the download glyph for the unsaved Save state.  
   `src/QuickAccessOverlay.swift:455`
6. **Disabled strip buttons explain nothing on hover** (allinone) — In setSelectionAvailable(false) set each disabled button's toolTip to 'Select a region first', restoring the plain label when re-enabled.  
   `src/SelectionOverlay.swift:1172`
7. **Section eyebrows nearly invisible on dark chrome** (annotator-panels) — Bump eyebrow color from tertiaryLabelColor to secondaryLabelColor (or ~60% white) and/or 11pt, keeping the kerned-uppercase style.  
   `src/Annotator/AnnotatorWindow.swift:624`


## 🔴 HIGH (9)

### Strip looks dead/broken before a region is selected, with its only guidance stranded at the top of the screen
`allinone` · ux · effort M  
In allInOne mode the strip shows immediately, then setSelectionAvailable(false) greys 6 of 8 buttons (Capture/Record/GIF/Scrolling/OCR/Pin) to 0.35 alpha and disables both W/H fields, so the whole left cluster reads as broken. The one hint ('Select, then pick an action below') is drawn at topInset+16 — the TOP of the screen — while the strip sits at the bottom, so on a large display the precondition is nowhere near the dead-looking toolbar.  
**Fix:** Give the strip an inline empty-state: when no selection is held, overlay the greyed cluster with a single caption inside the pill ('Drag anywhere to select a region'), or delay showing the action buttons until hold() fires and only expose W/H + Timer + Cancel up front.  
**Anchor:** `src/SelectionOverlay.swift:212 (also :922-934 hint pill placement)`

### Inverted hierarchy: primary Capture(⏎) is greyed while secondary Fullscreen is the only lit button and reads as pre-selected
`allinone` · ux · effort M  
Capture is the documented default (tooltip 'Capture (⏎)', accent-tinted) yet it's disabled until a region exists, so before selection the primary affordance is a dead accent ghost and Return does nothing useful. Meanwhile Fullscreen — the only needsSelection:false capture button — is lit, and because StripHoverButton's hover wash (white 12%) is visually identical to a selected/active state, a transient hover reads as a committed mode (the owner's 'Fullscreen looks highlighted' impression).  
**Fix:** Give momentary buttons a distinct pressed style so hover never reads as selected; when no region is held, promote Fullscreen as the visible primary (accent tint) instead of leaving Capture accent-tinted-but-dead, and map Return to whichever action is currently primary.  
**Anchor:** `src/SelectionOverlay.swift:1030 (also :1233-1240 hover wash, :1071 Capture default)`

### Editors close with unsaved edits and no "save?" prompt — silent data loss
`annotator + video-editor` · bug · effort M  
Both AnnotatorWindowController (windowWillClose only, no windowShouldClose, no dirty tracking — AnnotatorWindow.swift:243) and VideoEditorController (VideoEditor.swift:81) tear the window down immediately on Cmd-W or the red button. Arrows/adjustments/background/crop on a fresh capture, and worse an external Finder image or video opened for in-place save, vanish with zero warning. This is the biggest dead-end in the app.  
**Fix:** Track a dirty flag (set on any canvas mutation/undo registration, cleared in save paths). Implement windowShouldClose to run a Save/Discard/Cancel NSAlert when dirty, reflect it in the window's documentEdited dot, and reuse the same alert for the video editor. Keep immediate close for onBurnIn no-op modes.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:243 (also src/VideoEditor.swift:81)`

### Opening a panel doesn't recenter the canvas — the image drifts off-center and clips behind the opposite panel
`annotator-panels` · bug · effort M  
panelWidthChanged() grows the window by the panel width and calls zoomOutToFitIfNeeded(), but that helper only ever ZOOMS (centered on the current midpoint) and never scrolls the document back to the center of the new, narrower viewport. Near a screen edge the window can't grow the full 190pt, the clip region shrinks, and the leftover scroll offset leaves the image jammed to one side and partly hidden behind the opposite panel — the user must manually scroll or hit Fit after every toggle.  
**Fix:** After layoutSubtreeIfNeeded() in panelWidthChanged, compute the origin that centers the backdrop within the clip (minus insets) on both axes and call scrollView.contentView.scroll(to:)/reflectScrolledClipView, then run the fit check.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:1846`

### Fill swatches never show which background is currently selected
`annotator-panels` · bug · effort S  
Every fill swatch is built with the same 1pt separatorColor border and nothing marks the active fill, so with a Dusk gradient applied to the canvas no swatch is highlighted — and after reopening the panel the selection is invisible. The EFFECTS grid, by contrast, already sets borderWidth=2 on the selected thumbnail, so the two grids behave inconsistently.  
**Fix:** Track the selected fill and give the matching swatch an accent selection ring (borderWidth 2 + HUDStyle.accent or an outer halo), updated in backgroundFillTapped and when rebuildBackgroundSidebar runs so it persists across reopen.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:908`

### No numeric value on any slider (padding, corners, and every adjustment)
`annotator-panels` · ux · effort M  
Neither the background sliders (PADDING/CORNERS) nor the adjustment sliders render their current value, so the user drags blind — can't tell padding is 48 vs 80px, corner radius 12 vs 28, or Exposure +0.4, and the neutral/zero point on bipolar sliders (Temperature, Tint) is ambiguous. This also makes reproducing a look across images impossible. Every comparable editor shows a live value beside the label.  
**Fix:** Add a right-aligned value field to each slider row (reuse the label+spacer+reset structure), showing px for padding/corners and a signed/percent value for adjustments, updated in the change handlers. Optionally make it an editable NSTextField for precise entry.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:737 (also :959 bg slider helper)`

### Hover row exposes only 4 actions; OCR, Send-to, Convert, Move-to-Bin are hidden behind un-hinted right-click
`qao` · ux · effort M  
On hover a saved still shows only Copy/Reveal/Annotate/Pin (QuickAccessOverlay.swift:451). The app's differentiating actions — Copy Text (OCR), Convert To, Send to (the Sentry destinations), Move to Bin — live only in rightMouseDown (662-716) with no visible cue a context menu exists, so a normal user never finds them. This buries exactly what sets the app apart from macOS's built-in screenshot HUD.  
**Fix:** Refactor the right-click menu into a shared makeMenu(), then add an 'ellipsis.circle' QAOIconButton to the hover row that calls NSMenu.popUpContextMenu with it, so every action is reachable from one discoverable control that stays in sync with right-click.  
**Anchor:** `src/QuickAccessOverlay.swift:451`

### "Edit Recording" → Save irreversibly overwrites the only copy with no confirmation
`video-editor` · bug · effort M  
saveTapped calls SentryStore.updateVideoMedia(recordID:) which replaces the record's media in place — trim, speed, volume/mute, crop, and burned-in annotations all baked into the overwrite with no versioning or undo. Save is the accent default (⏎) while the non-destructive 'Save as Copy…' is only secondary, so the one-way door is the path of least resistance; hitting Return after previewing a trim destroys the untrimmed original.  
**Fix:** Gate the in-place record overwrite behind a 'Replace the original recording? This can't be undone.' NSAlert when the edit is destructive (shorter trim, speed≠1, crop, or burn-in), or keep the pre-edit media as a one-level backup. Skip the prompt for a no-op save.  
**Anchor:** `src/VideoEditor.swift:598`

### AVPlayerView inline controls duplicate the app's chrome — two volumes, two scrubbers, orphan AirPlay/PiP
`video-editor` · ux · effort M · **needs Fable**  
controlsStyle=.inline makes the system player paint its own transport over the video: AirPlay/PiP top-left, a volume slider+speaker top-right, and a play/skip/scrub pill — on top of the app's OWN volume slider and filmstrip timeline. The user sees two volume controls (the top-right one only changes preview, so lowering it then hitting Save exports at the wrong level — a loss-of-intent bug) and two scrubbers with different notions of the clip's bounds (the player scrubber can seek outside the trimmed range and desync the filmstrip). This is the app's worst redundancy and the source of the owner's 'four scattered zones'.  
**Fix:** Set playerView.controlsStyle=.none and own all transport in-app: keep the single app volume slider (wired to both AVPlayer.volume preview and the export mix) and the filmstrip as the only scrubber. This collapses four zones to two and removes the AirPlay/PiP button and duplicate volume outright.  
**Anchor:** `src/VideoEditor.swift:168 (with duplicate custom controls at :207-216, :263)`


## 🟠 MEDIUM (26)

### Self-timer silently does nothing for Record, GIF, and Scrolling
`allinone` · ux · effort M  
The Timer button is always enabled and cycles 3/5/10s, and stripPicked copies timerSeconds onto every selection, but the allInOne dispatch only honors the countdown for still/copyText/pin in captureAfterTimer; the .recordVideo/.recordGIF/.scrollingCapture cases start immediately and ignore timerSeconds. A user who sets '5s' and clicks Record gets an instant recording with no countdown — a broken affordance for exactly the actions where staging the screen matters most.  
**Fix:** Either run the countdown before RecordingController.start/ScrollingCaptureController.begin, or grey out/hide the Timer button (and reset timerSeconds) once a record/scroll action is targeted, so the control never lies.  
**Anchor:** `src/AppDelegate.swift:189`

### W×H entry is tiny, unlabeled, unit-less, and starts disabled — reads as dead chrome
`allinone` · ui · effort S  
The two size fields are 48pt with only 'W'/'H' placeholders, no 'px' unit or caption, and default to isEnabled=false until a selection exists, so at launch they look like dead grey boxes. Their small controlSize and roundedBezel sit at a different weight/baseline than the 44pt icon buttons, breaking the row's vertical rhythm.  
**Fix:** Widen the fields, add a trailing 'px' unit or 'Size' caption, give the disabled state a placeholder rather than dead-grey look, and consider keeping them enabled (typing a size creates a centered selection) instead of gating on an existing selection.  
**Anchor:** `src/SelectionOverlay.swift:1115`

### Disabled action buttons give no reason for being disabled — tooltip just repeats the label
`allinone` · ux · effort S  
Each greyed button's toolTip is set to its own label ('Record', 'GIF', etc.), so hovering a disabled button tells the user nothing about the precondition. A user staring at six dimmed buttons has no on-hover path to learn 'select a region first', making the disabled state entirely opaque.  
**Fix:** In setSelectionAvailable(false) set each disabled button's toolTip to an explanatory string ('Select a region first'), restoring the plain label when re-enabled.  
**Anchor:** `src/SelectionOverlay.swift:1172`

### Save / Save As placement and style are inconsistent within the annotator and across editors
`annotator + video-editor` · consistency · effort M  
Annotator's primary Save is a small accent button top-right in the toolbar while Save As… is a grey accessoryBar button in the bottom zoom/dimensions strip — the two most-paired commands are spatially divorced and Save As reads as a zoom-bar utility. Across editors it's worse: video editor puts Save + 'Save as Copy…' together bottom-right as .rounded buttons, so the same concept differs in label, placement, and bezel, breaking muscle memory between image and video editing.  
**Fix:** Add shared makePrimarySave()/makeSaveAs() helpers, co-locate Save + its secondary in the same corner of both editors (e.g. a split-button with a chevron menu holding 'Save As…'/'Export…'), use one secondary label ('Save as Copy…'), and keep the annotator footer to dimensions + zoom only.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:423 & :524 (also src/VideoEditor.swift:245)`

### Footer shows "100%" twice — a readout and a button with identical text
`annotator-chrome` · consistency · effort S  
The zoom cluster renders zoomLabel (non-interactive percentage) immediately before a zoomActual button also titled '100%'. At actual size both read '100%' side by side and the user can't tell the live readout from the reset action; clicking the more-discoverable readout does nothing. This is the Figma/Preview pattern done wrong — there the percentage readout IS the clickable control.  
**Fix:** Delete the zoomActual button and make zoomLabel itself the actual-size control (wrap in a button, or a small Fit/100%/200% pop-up) wired to zoomActualTapped with the 'Actual size (⌘0)' tooltip.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:514`

### Toolbar packs ~23 dim monochrome glyphs at low contrast, killing scannability
`annotator-chrome` · ui · effort M · **needs Fable**  
Every idle tool button is tinted secondaryLabelColor at 14pt medium, and 23+ sit in one 44pt row on the dark titlebar, so the whole set reads as a uniform grey smear with no anchor — the eye can't find crop vs draw vs redact without hovering each for a tooltip. Only the selected tool and the blue Save get contrast.  
**Fix:** Raise idle icon tint toward ~0.7 alpha (not 0.5), and collapse the low-frequency cluster (heal, clone, spotlight, magnifier, counter) into an overflow 'more tools' popover or a second togglable row so the always-visible set is ~10 high-frequency tools.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:465`

### Mode-tools and fire-once actions look identical, so users can't predict a tap
`annotator-chrome` · consistency · effort M  
The row mixes three behaviors behind identical 32×28 monochrome icons: persistent tools (crop/arrow/text arm a mode), panel toggles (background/adjust open a column), and one-shot actions (rotate opens a menu, Remove Background fires immediately, send/pin/copy act instantly). Nothing distinguishes them, so tapping Remove Background or Rotate mid-annotation is a surprise; only tools and the two toggles get a selected-state background.  
**Fix:** Give the three classes distinct affordances: keep tool toggles; render menu/action buttons (rotate, removeBG) with a trailing chevron or different treatment; and separate the panel toggles from the tool groups with a divider so they read as chrome, not tools.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:346`

### Cryptic glyphs: clone=scope, spotlight=rays, redact=checkerboard, and Magnify collides with zoom
`annotator-chrome` · ui · effort M  
Clone Stamp uses 'scope' (reads as target/aim), Spotlight uses 'rays' (reads as brightness), Redact uses 'checkerboard.rectangle' (reads as transparency, not censoring). The Magnify tool's 'plus.magnifyingglass' also conceptually collides with the footer zoom controls, so users mistake the annotation tool for a zoom button. With no labels these are pure guess-and-hover.  
**Fix:** Swap to clearer symbols (Clone → 'stamp'/'square.on.square.dashed'; Spotlight → a mask glyph; Redact → 'eye.slash' or a solid bar), differentiate Magnify from zoom, and ideally show text labels on hover-delay or in an overflow menu.  
**Anchor:** `src/Annotator/AnnotatorModels.swift:37`

### Toolbar overflows and clips at narrow window widths
`annotator-chrome` · bug · effort M  
The tool stack is ~23 fixed 32pt buttons (~800pt+) with no compression, wrap, or scroll, and the action cluster is pinned to the trailing edge. contentMinSize is 560×420, far below the toolbar's intrinsic width, so once the window narrows past ~1080pt content the trailing constraint is unsatisfiable — Auto Layout breaks and tools clip or overlap the undo/Save cluster with no way to reach the hidden ones.  
**Fix:** Wrap the tool stack in a horizontal NSScrollView or an overflow chevron that spills excess tools into a menu when width is constrained, and/or raise contentMinSize.width to the toolbar's true intrinsic width, keeping the action cluster and Save always reachable.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:441`

### Group dividers are inconsistent — chrome injected into crop group, sticker/watermark trail Select
`annotator-chrome` · consistency · effort S  
toolbarGroups defines clean dividers, but four chrome buttons (rotate, removeBG, background, adjust) are insertArrangedSubview into positions 2–5, landing inside the crop/lift group with no divider, so six mixed-purpose icons read as one group; and sticker/watermark are appended after the Select group with no separator, merging into one run. The grouping the dividers were meant to provide is undermined.  
**Fix:** Model the chrome/insert buttons and sticker/watermark as their own entries in toolbarGroups (or add explicit dividers around them) so every semantic cluster is bounded by a divider consistently.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:346`

### Panels don't identify themselves — left header reads only "FILL", right only "EFFECTS"
`annotator-panels` · ux · effort S  
The left panel opens from the Background (B) button but its first and only heading is the eyebrow 'FILL' (ambiguous — fill of what?), with no title saying the column is the Background workspace. The right panel has the inverse problem, leading with 'EFFECTS' and never saying 'Adjustments'. Neither column identifies itself, which is worst when both are open.  
**Fix:** Add a bolder ~13pt semibold panel title row atop each column ('Background' left, 'Adjustments' right), keeping FILL/PADDING/EFFECTS/LIGHT as tracked sub-section eyebrows beneath.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:951 (and :682)`

### Left panel is sparse and top-loaded while the right is dense — the columns are badly balanced
`annotator-panels` · ui · effort M  
The background sidebar holds only a swatch grid, two sliders, and a checkbox, all pinned to the top with no bottom distribution, leaving ~60% of the 190pt column empty, while the right inspector is packed edge to edge. Two equal-width panels of wildly unequal density make the window feel lopsided and waste the squeeze imposed on the canvas.  
**Fix:** Either narrow the background panel (it needs far less than 190pt) or fill it with useful controls (shadow intensity slider, aspect/inset presets, a custom color well) so both columns are balanced and the canvas keeps more room.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:870`

### EFFECTS thumbnails are tiny (50×34), unlabeled, and near-indistinguishable
`annotator-panels` · ui · effort M  
Effect buttons are 50×34 imageOnly with the name only in a tooltip, so the 8 thumbnails are a grid of almost identical rectangles — Mono, Tonal, Noir, Fade can't be told apart — and the selected one is marked only by a hairline 2pt border. Users can't browse looks without hovering each for a tooltip.  
**Fix:** Enlarge the tiles and add a short caption below each (or a 2-column name+preview list), and make the selection state a filled accent ring/checkmark rather than a hairline border so it reads at a glance.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:685`

### The two panels use different control vocabularies (per-row reset, button styles, checkbox)
`annotator-panels` · consistency · effort M  
The adjustment inspector gives every slider a label+spacer+reset row and uses bezeled accessoryBar buttons for Auto-Enhance/Reset, while the background panel's PADDING/CORNERS sliders have a bare eyebrow and no reset, and Shadow is a stock AppKit checkbox matching neither. Side by side the columns expose two visual languages for the same class of control.  
**Fix:** Unify one slider-row component across both panels (same typography, optional per-row reset, same value readout) and restyle the Shadow toggle to match (or convert to the same labeled-row + switch used elsewhere).  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:959 (vs :737)`

### Background palette is thin: only White + Charcoal solids, no black, no custom color
`annotator-panels` · ux · effort M  
solidPresets contains just White and Charcoal plus 5 gradients, and the 'No background' slash-circle sits inside the same swatch row as real colors, reading like a color. There's no pure black, no neutral grays, and no way to pick an arbitrary fill or sample one from the image — a notable gap for a background/beautify feature where brand colors matter.  
**Fix:** Broaden the solids (black, a couple of neutral grays), add a custom color well / eyedropper swatch opening NSColorPanel, and separate the 'None' control visually from the color swatches so it isn't mistaken for a color.  
**Anchor:** `src/Annotator/AnnotatorModels.swift:196 (and AnnotatorWindow.swift:929)`

### Section eyebrows are too low-contrast (tertiaryLabelColor, 10pt) to scan on dark chrome
`annotator-panels` · ui · effort S  
All section heads — FILL, PADDING, CORNERS, EFFECTS, LIGHT, COLOUR, DETAIL, ADVANCED — use tertiaryLabelColor at 10pt, rendering as very dim gray against the dark editor tint and nearly disappearing, which hurts the exact structural cues users rely on to navigate two dense panels.  
**Fix:** Bump eyebrow color to secondaryLabelColor (or ~55-65% white) and/or 11pt, keeping the kerned-uppercase style so headings pass legibility on the dark surround.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:624 (and :897)`

### QAO Save then Annotate forks a duplicate record instead of editing the saved one
`qao` · bug · effort S  
saveOrRevealAction (fileURL==nil path) calls reExport and updates item.fileURL/recordID, but DeliveredCapture.payload is a `let`, so the embedded .still's recordID stays nil. annotateAction, the card-body click, copyTextAction, convertAction, and drag-out all extract that stale payload, so the annotator opens with recordID==nil and its Save creates a SECOND record. The user ends up with duplicate history entries and edits that don't land on the file they just saved.  
**Fix:** After reExport, re-wrap the item with a rebuilt payload carrying the new recordID (store a mutable still, re-create DeliveredCapture(payload:.still(updatedStill), fileURL:, recordID:)) so every downstream action keys off the saved record.  
**Anchor:** `src/QuickAccessOverlay.swift:735`

### Action buttons and close X have no resting affordance — bare glyphs read as decoration
`qao` · ui · effort S  
QAOIconButton only paints a background on individual mouseEntered; at rest the 4 hover icons and the close X are borderless tinted glyphs with no container, so on the dim scrim they look like watermark decoration until hovered, tap targets aren't obvious, and the row reads as ambiguous.  
**Fix:** Give each QAOIconButton a persistent subtle circular background (white @0.10, cornerRadius=size/2) that brightens on hover, and optionally group the action row inside a single rounded pill so they read as a control set at rest.  
**Anchor:** `src/QuickAccessOverlay.swift:919`

### The chevron pill reads as a stray empty pill below the stack
`qao` · ui · effort S  
QAOChevronPanel is a 36×20 pill containing only a 10pt chevron tinted white @0.75, detached 8px below the stack with no label. Users don't know it hides/shows the stack, and when the stack is hidden it's the only remaining control — an unlabeled empty pill the user must guess is 'bring my captures back'.  
**Fix:** Make it legible: chevron ~13pt at full white, and when collapsed show a count badge or short label (chevron.up + N) so a hidden stack advertises itself; consider widening the pill or only showing it when the pointer is near the corner.  
**Anchor:** `src/QuickAccessOverlay.swift:229`

### Caption repeats the full generated filename on every card, giving no recency cue
`qao` · ux · effort M  
refreshCaption sets captionName to the full lastPathComponent ('Sentry Capture 2026-07-03 at 21.48.49.png'), so every card shares the identical prefix and the only distinguishing token is a raw HH.MM.SS timestamp. The stack orders newest-at-corner but nothing on the card states recency, so the owner's 'unclear which is newest' complaint is real.  
**Fix:** Show a friendly relative time ('Just now', '2m ago') as captionName, keeping dimensions/size in captionMeta and the full filename in the tooltip/Reveal action.  
**Anchor:** `src/QuickAccessOverlay.swift:523`

### Clicking the card body silently opens the annotator, duplicating the Annotate button
`qao` · ux · effort M  
mouseUp on an expanded still opens OutputRouter.openAnnotator and dismisses the card, while a dedicated Annotate button does exactly the same thing. A user who clicks the thumbnail to inspect it is thrown into full edit mode with no affordance, and the click target's meaning changes by state (collapsed=expand, expanded=annotate), which is hard to predict.  
**Fix:** Make a plain click a lightweight preview/quick-look and reserve annotation for the explicit button (and double-click), or add a visible 'Click to annotate' hover hint; since the whole body annotates, the redundant Annotate glyph could be dropped to free space for higher-value actions.  
**Anchor:** `src/QuickAccessOverlay.swift:584`

### Cards are large and the 5-high stack walls off the whole left screen edge
`qao` · ui · effort M  
Each card is 240 wide with thumbnail height up to 170 plus a 22 caption; with maxCards=5 and 8px gaps the stack can occupy ~900px of vertical edge, dominating the corner and covering content behind it on a laptop display — the opposite of a 'stay out of the way' post-capture HUD.  
**Fix:** Reduce the default footprint: cap thumbnail height lower (~120), narrow the card to ~200, collapse after 2 full cards instead of 3, and/or make card size a preference — a stack that peeks rather than blankets the edge.  
**Anchor:** `src/QuickAccessOverlay.swift:376`

### Long encodes (scrolling composite delivery) freeze the app with no progress feedback
`systemic` · ux · effort M  
deliver(_:) is @MainActor and encodes synchronously on the main thread; the code itself notes a scrolling composite 'costs seconds per encode'. During those seconds the menu bar, overlays, and open windows are frozen with no spinner, toast, or sound — after a scrolling capture the overlay vanishes and then nothing appears for several seconds, reading as a hang or failed capture.  
**Fix:** Show an immediate 'Processing capture…' toast/HUD (or push a placeholder QAO card) before the blocking encode, and/or move the persist+encode off-main and hand the record back on completion.  
**Anchor:** `src/OutputRouter.swift:31`

### Primary CTAs are system-blue everywhere while the brand accent is amber
`systemic` · consistency · effort M  
Every default button (annotator Save, video Save, Record, Scrolling Done, Batch Convert, Export) sets bezelColor=.controlAccentColor (system blue) while every custom surface — strip active glyph, QAO cards, selection marquee, annotator active-tool pill — uses the amber HUDStyle.accent. So the annotator shows an amber active-tool pill and a blue Save in the same toolbar, and the most-emphasized control in each window is a color that appears nowhere else in the app.  
**Fix:** Add a HUDStyle.primaryButton(title:) helper that sets bezelColor=HUDStyle.accentDeep (or overrides controlAccentColor app-wide), and route the six CTA call sites through it so the primary color matches the brand accent.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:427 (+ VideoEditor.swift:252, Recorder.swift:1008, ScrollingCapture.swift:133, BatchConvert.swift:153, ExportDialog.swift:313)`

### Crop, Annotate, and Frame-grab stay clickable during an export
`video-editor` · bug · effort S  
setBusy disables speedPopup/sizePopup/volumeSlider/gifButton/copyButton/saveButton and the timeline, but omits frameButton, cropButton, and annotateButton. Mid-export you can toggle crop, open the annotator, or grab a frame while an AVAssetExportSession is in flight, mutating state (crop/burnOverlay) the running composition already captured.  
**Fix:** Add frameButton, cropButton, and annotateButton to the controls array in setBusy so all mutating/opening actions disable while exporting.  
**Anchor:** `src/VideoEditor.swift:579`

### Bottom bar mixes cryptic icon-only buttons with text buttons and offers no grouping
`video-editor` · ui · effort M  
The bar runs speed popup, size popup, speaker+slider, camera icon, crop icon, annotate icon, GIF…, Save as Copy…, Save — icon-only glyphs sit shoulder-to-shoulder with worded buttons and popups with no dividers. The camera icon reads as 'take a screenshot' rather than its real meaning 'open the current frame in the image editor', with only a tooltip to disambiguate. The eye can't parse edit-tools vs export-actions.  
**Fix:** Group with NSBox separators/custom spacing into [playback: play, time] · [preview: speed, size, volume] · [tools: frame-grab, crop, annotate] · [export: GIF…, Save as Copy…, Save], and give the three tool buttons short leading-image labels ('Grab Frame', 'Crop', 'Annotate') to match the worded export buttons.  
**Anchor:** `src/VideoEditor.swift:262`


## 🟡 LOW (16)

### Timer control gives no hint it cycles, and divider/field heights break the row rhythm
`allinone` · ui · effort S  
The Timer button silently cycles Off→3→5→10s with no chevron/badge/indicator that repeated taps change it, so discoverability is poor. Separately the vertical dividers are fixed at 26pt inside a 44pt row while the small-controlSize W/H fields sit at yet another height, so the left cluster reads as three different vertical weights.  
**Fix:** Add a cycling affordance to Timer (small chevron or count badge) and/or a 'Click to cycle 3/5/10s' tooltip, and normalize the divider height and field baseline to share the 44pt row's optical center.  
**Anchor:** `src/SelectionOverlay.swift:1199`

### Image dimensions are displayed twice — window title and footer
`annotator-chrome` · consistency · effort S  
refreshImageMeta sets the window title to '… — 1593x724' and the footer dimensionsLabel to '1593 × 724 px' simultaneously, with inconsistent formatting ('x' vs '×', no px vs px). Two live readouts of the same value looks redundant and unpolished.  
**Fix:** Keep the footer readout (near the zoom, where dimensions belong) and drop the size from the title; if both stay, unify the formatting.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:574`

### lift and Remove Background are adjacent and semantically overlapping
`annotator-chrome` · ui · effort S  
Lift Subject (wand.and.stars) and Remove Background (person.and.background.dotted) are placed next to each other and both operate on subject/background separation — one keeps the subject, one drops the background — with no labels and similar intent, so users won't know which is which or why there are two.  
**Fix:** Either merge into one 'Remove/Isolate Background' control with a mode toggle, or give each an unambiguous icon and separate them so they don't read as duplicates.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:368 (AnnotatorModels.swift:36)`

### Both panels can be open at once with no regard for whether the workflow needs it
`annotator-panels` · ux · effort M  
Background and Adjustments toggle independently; opening both adds ~380pt of chrome and triggers the off-center squeeze. Background styling and image adjustments are rarely tuned in the same beat, so dual-open mostly costs canvas real estate.  
**Fix:** Treat them as mutually-preferring (opening one collapses the other) or dock both into a single right-hand inspector with a segmented Background/Adjust switch, so the canvas only ever pays for one column. If true side-by-side is wanted, land the recenter fix first.  
**Anchor:** `src/Annotator/AnnotatorWindow.swift:1479 (and :1578)`

### Double-clicking a GIF recording in History reveals it in Finder despite a play-circle overlay
`history` · consistency · effort S  
History cards render a prominent play-circle overlay on every video record including GIFs, signaling 'this plays', but openRecord routes anything that isn't image/* or video/mp4 to activateFileViewerSelecting, so double-clicking a GIF just highlights it in Finder — no playback or edit. The play affordance and the actual action disagree.  
**Fix:** For GIF records open in a lightweight preview (NSWorkspace.open to the default GIF app, or an internal QuickLook/pin viewer) rather than only revealing in Finder, or drop the play-circle overlay on GIF cards.  
**Anchor:** `src/SentryRegistry.swift:159`

### "Recent Captures" menu only reveals in Finder — no way to reopen for editing
`menu` · consistency · effort S  
openRecent does activateFileViewerSelecting, so the status-menu Recent Captures submenu can only reveal files, while History double-click and QAO card click reopen the capture in the editor. The fastest path back to a capture is the only one that can't reopen it to annotate — a user picking a recent to touch it up is dropped into Finder.  
**Fix:** Make recent items call SentryRegistry.openRecord (open in editor) on click, with a modifier (⌥) or submenu item for 'Reveal in Finder', matching History/QAO semantics.  
**Anchor:** `src/AppDelegate.swift:452`

### Hover scrim dims the whole card 45% black, obscuring the thumbnail being acted on
`qao` · ui · effort S  
setHover fades a black @0.45 scrim over the whole card including the caption, which already carries its own black @0.35, so on hover the caption stacks to a very dark low-contrast strip and the thumbnail is muddied right when the user is deciding an action.  
**Fix:** Lower the full-card scrim to ~0.25-0.30, or apply the darker dim only to the thumbnail region (not the caption), or use a soft gradient behind just the button cluster so the image stays readable.  
**Anchor:** `src/QuickAccessOverlay.swift:447`

### captionMeta is borderline legible and info density is inconsistent between cards
`qao` · ui · effort S  
captionMeta is white @0.55, dim on bright wallpapers over the semi-transparent band, and size+extension only appear when a fileURL with bytes>0 exists, so some cards read '1885×945 · 344 KB PNG' and others just '5120×1440' — inconsistent right-aligned columns down the stack.  
**Fix:** Raise meta alpha to ~0.7 and normalize the format (always dimensions, append size only when known) so the column stays visually consistent.  
**Anchor:** `src/QuickAccessOverlay.swift:502`

### Collapsed slivers show no clickable-to-expand affordance and can't be acted on until expanded
`qao` · ui · effort S  
Cards at index>=3 collapse to a 24px caption sliver; the only way to copy/annotate them is to click to expand first, but nothing signals the sliver is interactive or that its actions are hidden. A burst of captures turns older ones into inert strips with no hint how to get them back.  
**Fix:** Give collapsed slivers a subtle hover state (brighten background or show a small expand chevron) and/or a 'Click to expand' tooltip.  
**Anchor:** `src/QuickAccessOverlay.swift:134`

### Annotate glyph is unreadable at bar size across surfaces (reads as 'A' / 'circle-A')
`qao + video-editor` · ui · effort S  
The QAO Annotate button uses 'pencil.tip', which at 14pt on the scrim collapses to a wedge the owner read as 'A'; the video editor uses 'pencil.tip.crop.circle', which at 16pt reads as an ambiguous circle-with-a-mark. Neither communicates 'draw/mark up', and burn-in is a consequential action to hide behind an obscure glyph.  
**Fix:** Use a clearer markup glyph ('pencil.and.outline', 'scribble.variable') at both sites, and for the consequential video burn-in prefer a labeled button over icon-only.  
**Anchor:** `src/QuickAccessOverlay.swift:462 (and src/VideoEditor.swift:234)`

### 'Active/selected control' is drawn two different ways across surfaces
`systemic` · consistency · effort S  
The all-in-one strip signals its active control by tinting the glyph amber, while the annotator signals the active tool with a filled amber pill behind the glyph. Same semantic rendered two ways, so users learn the meaning twice.  
**Fix:** Pick one language and centralize it in HUDStyle (e.g. HUDStyle.setActive(button:on:) applying the accentDeep pill), then use it for both the strip's active glyph and the annotator's selected tool.  
**Anchor:** `src/SelectionOverlay.swift:1188 (vs src/Annotator/AnnotatorWindow.swift:581)`

### Corner-radius values are ad-hoc across nested controls (12/10/9/7/6/4)
`systemic` · consistency · effort M  
HUDStyle defines a single cornerRadius=12 for surfaces, but nested controls each pick their own radius with no scale — toolbar icon buttons 6, inspector buttons 4, background swatches 9, strip hover buttons 7, QAO action buttons 6 and 10 — so similar-sized chips end up visibly different between the annotator toolbar, the QAO overlay, and the strip.  
**Fix:** Add HUDStyle.controlRadius (~8) and HUDStyle.chipRadius (~6) tokens and replace the scattered literals so every control pulls from a 3-step radius scale.  
**Anchor:** `src/Toast.swift:8 (+ AnnotatorWindow.swift:467/694/915, SelectionOverlay.swift:1219, QuickAccessOverlay.swift:484/932)`

### Small-label typography drifts between 9.5/10/11/12 with no shared token
`systemic` · consistency · effort M  
Tiny text across chrome uses near-identical but non-matching sizes: strip labels 9.5, QAO meta 9.5 mono, QAO name 10, annotator eyebrow 10 semibold, footer 11 mono, selection caption 12, toast 13. There's no shared type ramp, and the tracked-uppercase eyebrow style used in the annotator panels never appears on QAO or the strip.  
**Fix:** Define a small HUDStyle type ramp (caption 10, meta 9.5-mono, body 13, eyebrow 10-semibold-kerned) as static NSFont tokens and route these call sites through them so sizes snap to a scale.  
**Anchor:** `src/SelectionOverlay.swift:925/1169 (+ QuickAccessOverlay.swift:498/501, AnnotatorWindow.swift:503/514/627, Toast.swift:76)`

### No play/pause or spacebar transport lives in the app's own chrome
`video-editor` · ux · effort M  
The only play/pause affordance today is AVPlayerView's inline pill; the bottom bar has no transport button and there's no keyDown handler, so spacebar works only while the player view is first responder. Once the inline controls are removed (required to fix the duplicate-chrome finding) there is no way to start playback at all.  
**Fix:** Add a play/pause NSButton (play.fill/pause.fill toggled on rate) at the left of the bar plus a keyDown override mapping spacebar, updating the glyph from the periodic time observer / rate KVO, with a current-time · duration readout to replace the player's.  
**Anchor:** `src/VideoEditor.swift:262`

### Speaker icon next to the volume slider looks like a mute toggle but isn't clickable
`video-editor` · ui · effort S  
The speaker glyph beside the app volume slider is a plain NSImageView, not a control. Users expect a speaker icon in a volume group to toggle mute (the universal affordance), but clicking does nothing; muting requires dragging the tiny 70pt slider to 0.  
**Fix:** Make the speaker an NSButton that toggles mute (store last non-zero level, restore on un-mute) and swaps its glyph speaker.wave.2 ↔ speaker.slash, keeping the slider for fine control.  
**Anchor:** `src/VideoEditor.swift:207`

### Portrait/narrow recordings leave large black letterbox dead-zones on both sides
`video-editor` · ui · effort M  
The player is pinned edge-to-edge inside a fixed 960×660 landscape window, so a portrait clip is aspect-fit with wide black bars left and right hosting nothing, pushing the video into a narrow central column while half the window is dead space. The window makes no attempt to match the video's aspect ratio.  
**Fix:** After loading orientedVideoSize, set window.contentAspectRatio (or size initial content) to the video's oriented aspect, and/or add a neutral checkerboard backdrop behind the letterbox so the dead-zone reads as intentional matte.  
**Anchor:** `src/VideoEditor.swift:65`
