# Image/video editing API cheat-sheet — "personal Photoshop" for Sentry Capture (macOS 15 target, swiftc, no third-party deps)

**Verification basis:** every signature below was grepped from the local **MacOSX26.5 SDK** headers (`$(xcrun --show-sdk-path)/System/Library/Frameworks/…`): `Vision.framework/Headers/*.h` **and** the Swift-native `Vision.swiftmodule/arm64e-apple-macos.swiftinterface`, `CoreImage.framework/Headers/CIFilterBuiltins.h` + `CIContext.h` + `CIImage.h`, `ImageIO.framework/Headers/CGImageDestination.h`, `AVFoundation.framework/Headers/{AVVideoComposition,AVAssetImageGenerator,AVAssetExportSession}.h`, `ImagePlayground.framework`. The ImageIO read/write format lists in §5 were **enumerated at runtime** by compiling and running a probe against `CGImageSourceCopyTypeIdentifiers()` / `CGImageDestinationCopyTypeIdentifiers()` with `swiftc -target arm64-apple-macos15.0` on this machine — that list is authoritative for *this* SDK/OS, not a guess. Items I could not exercise with real pixels (no model-download / GPU-timing measurements taken here) are marked **UNVERIFIED (behavioural)** — the *signatures* are verified, the *quality/latency claims* are from Apple docs/WWDC and not measured locally.

**Deployment target 15.0** — everything marked macOS 15.0 or lower is usable unguarded. macOS 26.0 items must be `if #available(macOS 26, *)`-gated (there are only a few, all optional niceties).

**Imports:** `import Vision`, `import CoreImage`, `import CoreImage.CIFilterBuiltins` (typed filter accessors), `import ImageIO`, `import UniformTypeIdentifiers`, `import AVFoundation`, `import CoreVideo`, `import AppKit`. Auto-linking under swiftc pulls the frameworks in; no `-framework` flags needed normally.

---

## Availability matrix (from SDK headers — authoritative)

| API | macOS |
|---|---|
| `VNGeneratePersonSegmentationRequest` (+ `qualityLevel` fast/balanced/accurate), `VNGenerateAttentionBasedSaliencyImageRequest` rev1, `VNGenerateObjectnessBasedSaliencyImageRequest` | 12.0 / 10.15 |
| `CIPersonSegmentation` filter | 12.0 |
| Attention/objectness saliency **rev2** (faster, less memory) | 14.0 |
| **`VNGenerateForegroundInstanceMaskRequest`** + `VNInstanceMaskObservation` (`instanceMask`, `allInstances`, `generateMask(forInstances:)`, `generateMaskedImageOfInstances:…`, `generateScaledMaskForImageForInstances:…`) | **14.0** |
| `VNGeneratePersonInstanceMaskRequest` (up to 4 people, separable) | 14.0 |
| `VNGeneratePersonSegmentationRequest.supportedOutputPixelFormats…` | 15.0 |
| **Swift-native Vision** (`ImageRequestHandler`, `GenerateForegroundInstanceMaskRequest` struct, `InstanceMaskObservation.instanceAtPoint(_:)`, `.perform(on:)`) | **15.0** |
| Core Image adjustment set (`CIColorControls`, `CIExposureAdjust`, `CIVibrance`, `CITemperatureAndTint`, `CIHighlightShadowAdjust`, `CIToneCurve`, `CIColorCurves`, `CIGammaAdjust`, `CIUnsharpMask`, `CISharpenLuminance`, `CIVignette*`, `CIAreaHistogram`, `CILanczosScaleTransform`, `CIBicubicScaleTransform`, `CIStraighten`, `CIBlendWithMask`, `CIColorMatrix`, `CIColorPolynomial`, `CIConvolution`, `CIMorphology*`, `CIMedian`) | 10.4–12 (all pre-15) |
| `CIContext.writeHEIF10Representation…`, `CIToneMapHeadroom` filter | 15.0 |
| `CIToneCurve.extrapolate`, `CISystemToneMap` filter | 26.0 |
| ImageIO read/write, all `CGImageDestination*` option keys (incl. HDR gain-map keys) | ≤15.0 |
| `AVVideoCompositionCoreAnimationTool` (`…WithAdditionalLayer:asTrackID:`, `…WithPostProcessingAsVideoLayer:inLayer:`) | 10.9 |
| `AVAssetImageGenerator.generateCGImageAsynchronouslyForTime:` | 13.0 (replaces now-deprecated `copyCGImageAtTime:`, dep. 15.0) |
| `ImagePlayground` `ImageCreator` (generative only — see §4) | 26.0 |

---

# 1. Subject lifting / segmentation ("copy subject", lift-the-cat)

This is the headline feature and Apple gives you a **first-class API for exactly it**: `VNGenerateForegroundInstanceMaskRequest`. It is what Preview/Photos "Copy Subject" / "Remove Background" is built on (Vision's subject-lifting model). It returns per-instance masks so you can lift *one* tapped subject or *all* of them.

Two API surfaces exist for the same model — use the **Swift-native one (macOS 15+)** since our target is 15.0; it's cleaner and gives you `instanceAtPoint`.

## 1a. Swift-native path (macOS 15+) — preferred

```swift
import Vision

/// Returns a cut-out CGImage (transparent background) of the subject nearest `pointN`
/// (normalised, origin bottom-left), or all subjects if pointN is nil.
func liftSubject(from cg: CGImage, at pointN: CGPoint?) async throws -> CGImage? {
    let handler = ImageRequestHandler(cg)                       // Vision.ImageRequestHandler
    var request = GenerateForegroundInstanceMaskRequest()      // macOS 15+
    guard let obs: InstanceMaskObservation =
        try await handler.perform(request) else { return nil } // .Result is InstanceMaskObservation?

    // Which instances to lift:
    let instances: IndexSet
    if let p = pointN {
        instances = obs.instanceAtPoint(NormalizedPoint(x: p.x, y: p.y)) // tap-to-pick one subject
    } else {
        instances = obs.allInstances                                     // everything vs background
    }
    guard !instances.isEmpty else { return nil }

    // High-res RGBA cut-out, everything but `instances` set to transparent black:
    let masked: CVPixelBuffer = try obs.generateMaskedImage(
        for: instances,
        imageFrom: handler,           // same handler that produced the observation
        croppedToInstancesExtent: true)   // tight-crop to the subject's bbox
    return CIContext().createCGImage(CIImage(cvPixelBuffer: masked),
                                     from: CIImage(cvPixelBuffer: masked).extent)
}
```

Verified members of `InstanceMaskObservation` (Swift interface):
- `let allInstances: IndexSet` — every instance index except background (0).
- `let allInstancesMask: PixelBufferObservation` — the raw label map.
- `func instanceAtPoint(_ point: NormalizedPoint) -> IndexSet` — **tap-to-select**. `NormalizedPoint(x:y:)` with origin bottom-left; also `NormalizedPoint(imagePoint:in:)` to convert from pixel coords for you.
- `func generateMask(for: IndexSet) throws -> CVPixelBuffer` — low-res soft mask at analysis resolution (`OneComponent32Float`, 0…1). Cheap; use for a *preview* selection outline.
- `func generateScaledMask(for: IndexSet, scaledToImageFrom: ImageRequestHandler) throws -> CVPixelBuffer` — mask **upscaled to full image resolution** (the alpha you composite with).
- `func generateMaskedImage(for: IndexSet, imageFrom: ImageRequestHandler, croppedToInstancesExtent: Bool = false) throws -> CVPixelBuffer` — full-res **RGBA cut-out** in one call (image × mask already applied). This is the "give me the PNG" shortcut.

`GenerateForegroundInstanceMaskRequest` also has `var regionOfInterest: NormalizedRect` (restrict analysis) and `setComputeDevice(_:for:)` (pin to GPU/ANE/CPU per stage).

## 1b. ObjC/classic Vision path (macOS 14+) — if you ever drop to a lower target

```swift
let req = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: cg, options: [:])
try handler.perform([req])
guard let obs = req.results?.first else { return }        // VNInstanceMaskObservation
let all = obs.allInstances                                 // NSIndexSet
let px  = try obs.generateMaskedImage(ofInstances: all,
                                      from: handler,
                                      croppedToInstancesExtent: true) // CVPixelBufferRef, RGBA
```
Classic path has **no `instanceAtPoint`** — for tap-to-pick you must read the label value out of `obs.instanceMask` (a `OneComponent8`/label `CVPixelBuffer`) at the tapped pixel yourself, then build the `NSIndexSet` from that label. That's the main reason to prefer 1a on our 15.0 target.

## 1c. Turning a mask into the two things you need

**(a) Cut-out CGImage with alpha** — either the one-call `generateMaskedImage` above, or composite manually with Core Image so you keep the original at full quality and control edge feathering:

```swift
let scaled = try obs.generateScaledMask(for: instances, scaledToImageFrom: handler) // full-res soft alpha
let maskCI = CIImage(cvPixelBuffer: scaled)
let cutout = CIImage(cgImage: cg).applyingFilter("CIBlendWithMask", parameters: [
    kCIInputMaskImageKey: maskCI,
    kCIInputBackgroundImageKey: CIImage.empty()   // transparent background
])
```

**(b) Selection path (marching-ants outline)** — Vision gives you a *raster* mask, never a vector path. To get a `CGPath`/`NSBezierPath` outline you must trace it yourself. There is **no public mask→path API**. Practical DIY:
- Threshold the soft mask at 0.5 → binary.
- Run a contour tracer. Vision ships one that's abusable: `VNDetectContoursRequest` (macOS 11+) run *on the mask image* returns `VNContoursObservation` whose `normalizedPath` is a ready `CGPath`. This is the cheapest no-dependency route to marching-ants. (Signature not re-verified here — mark **UNVERIFIED (behavioural)** for contour quality on soft masks; threshold first.)
- Or just render the mask edge as an animated dashed stroke by drawing the mask's alpha edge — most editors fake "marching ants" as a shimmer over the mask rather than a true path, which sidesteps tracing entirely.

## 1d. Saliency (cheap "what's the subject roughly")

`VNGenerateAttentionBasedSaliencyImageRequest` (rev2 on macOS 14) → `VNSaliencyImageObservation`: a **68×68** `OneComponent32Float` heat map (`.pixelBuffer`) plus `salientObjects: [VNRectangleObservation]` (bounding boxes of attention modes). Objectness variant (`VNGenerateObjectnessBasedSaliencyImageRequest`) favours whole objects over gaze. Use saliency for auto-suggesting a crop or a default subject box **before** the user taps — it's ~1000× cheaper than the segmentation model but far coarser (68px). Not a substitute for the instance mask when you need a clean edge.

---

# 2. Background removal ("automatic PNG")

Same `VNGenerateForegroundInstanceMaskRequest`, applied full-frame with `instances = obs.allInstances`, then invert-composite (keep foreground, drop background). That *is* automatic background removal — one model, no tuning.

- **Quality:** the foreground-instance model is the highest-quality general subject matte Apple ships on-device. Edge quality (hair, semi-transparency) is good but not a studio green-screen key. **UNVERIFIED (behavioural)** locally.
- **People specifically:** `VNGeneratePersonInstanceMaskRequest` (macOS 14) is tuned for humans and separates **up to 4 people** into distinct instances — better person edges + the ability to lift one person from a group. Same `VNInstanceMaskObservation` result, same `generateMaskedImage`. Use this when the subject is a person; fall back to the generic foreground request otherwise.
- **`VNGeneratePersonSegmentationRequest`** (macOS 12) is the older *single* combined-people matte with an explicit `qualityLevel`:
  - `.fast` — low accuracy, streaming/ANE, for live preview.
  - `.balanced` — high-accuracy mask.
  - `.accurate` (default) — balanced **plus matting refinement** (best edges; slowest).
  It produces one merged mask (no per-person instances) as a `VNPixelBufferObservation` (`OneComponent8`/`16Half`/`32Float`, set via `outputPixelFormat`). Prefer the instance requests for stills; keep this one only for a live 30/60fps preview path where `.fast` on the ANE matters.
- **Edge refinement:** there's no public "feather/refine matte" knob beyond `qualityLevel`. DIY edge cleanup on the alpha: `CIMorphologyMinimum`/`Maximum` (erode/dilate to bite in a pixel), then a 0.5–1px `CIGaussianBlur` on the mask before compositing to kill the aliased fringe. To decontaminate colour fringing, there's no public API — you'd multiply-composite over the chosen background and accept it.
- **Core Image shortcut:** `CIPersonSegmentation` (macOS 12) is the same person matte exposed as a filter (`qualityLevel: 0/1/2`) if you're already in a CIImage pipeline and want to stay there.

---

# 3. Core Image adjustments (exposure/contrast/colour/curves/sharpen/histogram)

All verified in `CIFilterBuiltins.h` (typed accessors via `CIFilter.<name>()`; properties below are exact). Everything here is ≥10.x — safe on 15.0.

| Adjustment | Filter (typed) | Key properties (verified) |
|---|---|---|
| Exposure (stops) | `.exposureAdjust()` | `EV: Float` |
| Brightness/contrast/saturation | `.colorControls()` | `brightness`, `contrast`, `saturation: Float` |
| Vibrance | `.vibrance()` | `amount: Float` |
| Temperature / tint (white balance) | `.temperatureAndTint()` | `neutral: CIVector`, `targetNeutral: CIVector` (both `(x=temp, y=tint)` in K/tint units) |
| Highlights / shadows | `.highlightShadowAdjust()` | `radius`, `shadowAmount`, `highlightAmount: Float` |
| Gamma | `.gammaAdjust()` | `power: Float` |
| Tone curve (5-point) | `.toneCurve()` | `point0…point4: CGPoint` (+ `extrapolate: Bool` on macOS 26 only) |
| Arbitrary curves (per-channel RGB) | `.colorCurves()` | `curvesData: Data` (float RGB samples), `curvesDomain: CIVector`, `colorSpace: CGColorSpace` |
| Channel matrix | `.colorMatrix()` | `RVector/GVector/BVector/AVector/biasVector: CIVector` |
| Polynomial per-channel | `.colorPolynomial()` | `red/green/blue/alphaCoefficients: CIVector` |
| Sharpen (unsharp mask) | `.unsharpMask()` | `radius`, `intensity: Float` |
| Sharpen (luminance) | `.sharpenLuminance()` | `sharpness`, `radius: Float` |
| Vignette | `.vignette()` / `.vignetteEffect()` | `intensity`, `radius` (+ `center`, `falloff` on the *Effect* variant) |
| Histogram | `.areaHistogram()` | `extent: CGRect`, `scale: Float`, `count: NSInteger` (# bins, e.g. 256) → outputs a 1×`count` image; pair with `.histogramDisplay()` to draw it |
| Blur | `.gaussianBlur()` | `radius: Float` |

**Curves note:** `CIToneCurve` is a fixed **5-control-point** spline (good for a simple curve UI). For a true multi-node curves editor (Lightroom-style) use **`CIColorCurves`** — you hand it a `Data` blob of RGB float samples over `curvesDomain` and a `colorSpace`. That's the one to build the curves tool on.

**Histogram:** `.areaHistogram()` returns the histogram *as a 1-pixel-tall image of `count` columns*, not a CPU array. To get numbers for a UI, `CIContext.render(_:toBitmap:…)` that tiny image into a `[Float]`. `.areaLogarithmicHistogram()` exists for log-scale.

## Applying a chain efficiently to a CGImage

```swift
import CoreImage
import CoreImage.CIFilterBuiltins

let ctx = CIContext(options: [                       // CREATE ONCE, reuse for the app's lifetime
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .cacheIntermediates: true,
])

func adjusted(_ cg: CGImage) -> CGImage {
    var img = CIImage(cgImage: cg)
    let e = CIFilter.exposureAdjust(); e.inputImage = img; e.ev = 0.3;  img = e.outputImage!
    let c = CIFilter.colorControls();  c.inputImage = img; c.saturation = 1.15; c.contrast = 1.05; img = c.outputImage!
    let v = CIFilter.vibrance();       v.inputImage = img; v.amount = 0.2; img = v.outputImage!
    // CIImage is a *recipe* — nothing runs until render. The whole chain fuses into one GPU pass.
    return ctx.createCGImage(img, from: CIImage(cgImage: cg).extent)!
}
```

**Colour-space pitfalls (the ones that bite):**
- Do colour math in a **linear** working space (`extendedLinearSRGB`), not gamma sRGB — blurs, blends, exposure are only physically correct in linear light. Set `.workingColorSpace` on the context, *not* per image.
- `CIImage(cgImage:)` carries the source's colour space and Core Image converts working↔output automatically. Don't hand-convert.
- **Premultiplied alpha:** cut-outs are premultiplied. `CIBlendWithMask`/`sourceOver` expect that; if you ever see dark halos it's an unpremultiply mismatch — use `img.unpremultiplyingAlpha()` / `premultiplyingAlpha()` deliberately.
- `createCGImage(_:from:)` needs a **finite extent**. Filters like blur/`CIImage.empty()` produce infinite extents — always pass an explicit rect (usually the original image extent) or `.cropped(to:)` first.
- Extended-range (HDR/gain-map) screenshots: keep `.workingFormat` at `RGBAh` (half-float) to avoid clipping; SDR clamps at 1.0.

---

# 4. Healing / inpainting — the hard truth

**There is no public on-device inpainting / content-aware-fill / object-removal API on macOS, including macOS 26.** Confirmed by header enumeration:
- **Core Image has no inpaint filter.** `CIFilterBuiltins.h` contains no `CIInpaint`, no `CIContentAwareFill`, no healing filter. (`CIMedian` and the `CIMorphology*` family exist but are denoise/morphology, not fill.) The old private `CIRetouch`/`CIPaintFilter` are not public.
- **Vision has no inpainting request** — it detects/segments, it does not synthesise pixels.
- **Photos' "Clean Up" and the Messages/Preview object-eraser are not exposed as an API.** They run a private generative model gated behind Apple Intelligence with no framework entry point.
- **`ImagePlayground.framework` (macOS 26) is *not* an inpainter.** Its public surface is `ImageCreator` + `ImagePlaygroundViewController` — **generative image *creation* from text `ImagePlaygroundConcept`s / a style**, not editing existing pixels. `CreationVariety`/`ImagePlaygroundStyle`/`ImagePlaygroundConcept` confirm this is prompt→new-image. It cannot take a screenshot + mask and heal a region. Also availability-gated (Apple Intelligence, region/device limited) and macOS 26-only. Do not build "healing" on it.

**Realistic DIY that ships with zero dependencies:**
1. **Clone stamp / heal brush** — the workhorse. Sample a source offset, composite the source region into the target through a soft round mask:
   ```
   result = CIBlendWithMask(background: canvas,
                            input:      canvas.transformed(by: sourceOffset),
                            mask:       softRoundBrushStamp)
   ```
   For a "healing" (texture-only) feel, match the sampled patch's mean luminance to the target before compositing (`CIColorControls` brightness delta, or add the low-frequency difference) so it blends like Photoshop's healing brush rather than a hard clone.
2. **Small-scratch / speck removal** — `CIMedian` (3×3 median) over a masked region kills dust/JPEG specks without a real inpaint.
3. **"Remove object" against a flat/blurred background** — segment the object (§1), delete it, and fill the hole by *stretching/blurring the surrounding background* (`CIGaussianBlur` of the plate + `CIBlendWithMask`). Works great for screenshots (usually flat backgrounds), poorly for textured photos.
4. **Content-aware fill quality** genuinely needs a diffusion model — out of scope for a swiftc/no-deps build unless you bundle a Core ML model yourself (that's a "third-party model", not a framework dependency, but a large binary + your own inference glue). Flag as future work; do **not** promise Photoshop-grade healing from public frameworks.

**Bottom line for the product:** ship clone-stamp + heal-brush + median-despeckle + segment-and-fill. Call it "Retouch", not "content-aware fill". Anything better requires a bundled ML model.

---

# 5. Format conversion (ImageIO) — what THIS SDK actually reads/writes

Enumerated at runtime on this machine (`CGImageSource/DestinationCopyTypeIdentifiers`). This is ground truth, not the docs.

**Readable (decode) — 70+ UTIs, highlights:**
`public.png`, `public.jpeg`, `public.tiff`, `public.heic/heif/heics`, `public.avif` + `public.avci/avis`, **`public.jpeg-xl` (JXL read ✓)**, **`org.webmproject.webp` (WebP read ✓)**, `public.jpeg-2000`, `com.compuserve.gif`, `com.microsoft.bmp/ico/cur/dds`, `com.adobe.photoshop-image` (PSD), `com.ilm.openexr-image`, `public.radiance` (HDR), `com.truevision.tga-image`, `public.mpo-image`, KTX/KTX2/ASTC/PVR (GPU textures), DICOM, and the full RAW zoo (`com.canon.cr3-raw-image`, `com.sony.arw-raw-image`, `com.nikon.raw-image`, Fuji/Panasonic/Olympus/…).

**Writable (encode) — 21 UTIs, the ones you care about:**

| Format | Write UTI | Notes |
|---|---|---|
| PNG | `public.png` | lossless, alpha. Interlace via `kCGImagePropertyPNGInterlaceType`. |
| JPEG | `public.jpeg` | `kCGImageDestinationLossyCompressionQuality` 0…1. No alpha. |
| **HEIC** | `public.heic` (+ `public.heics` sequence) | quality key; alpha ok; ~½ JPEG size. |
| **AVIF** | `public.avif` | write ✓ (AV1 still). quality key. |
| TIFF | `public.tiff` | lossless, alpha, 16-bit. |
| JPEG-2000 | `public.jpeg-2000` | quality key. |
| GIF | `com.compuserve.gif` | 256-colour, animation via multi-frame add. |
| BMP | `com.microsoft.bmp` | |
| **PDF** | `com.adobe.pdf` | **yes — you can wrap an image into a 1-page PDF straight through `CGImageDestination`** (no CGPDFContext needed for the simple case). |
| PSD | `com.adobe.photoshop-image` | flattened. |
| OpenEXR / DDS / ICO / ICNS / TGA / PVR / ASTC / KTX(2) / PBM | resp. | niche. |

**NOT writable in this SDK (hard limits):**
- **WebP: read-only, no encode.** (`org.webmproject.webp` is absent from the destination list.)
- **JPEG-XL: read-only, no encode.** (`public.jpeg-xl` absent from destinations.)
If the product needs to *export* WebP/JXL, ImageIO can't — you'd bundle a codec. Reading them is fine.

## Write pattern + options

```swift
import ImageIO
import UniformTypeIdentifiers

func write(_ cg: CGImage, to url: URL, as type: UTType, quality: CGFloat? = nil,
           stripMetadata: Bool = false, dpi: CGFloat? = nil) -> Bool {
    guard let dst = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    else { return false }
    var opts: [CFString: Any] = [:]
    if let q = quality { opts[kCGImageDestinationLossyCompressionQuality] = q }  // HEIC/JPEG/AVIF/J2K
    if stripMetadata {                                                            // privacy: drop EXIF GPS/XMP
        opts[kCGImageMetadataShouldExcludeGPS] = true
        opts[kCGImageMetadataShouldExcludeXMP] = true
    }
    if let d = dpi { opts[kCGImagePropertyDPIWidth] = d; opts[kCGImagePropertyDPIHeight] = d }
    CGImageDestinationAddImage(dst, cg, opts as CFDictionary)
    return CGImageDestinationFinalize(dst)
}
```

Verified `CGImageDestination` option keys of interest: `kCGImageDestinationLossyCompressionQuality`, `kCGImageDestinationImageMaxPixelSize` (downscale-on-write in one shot), `kCGImageDestinationEmbedThumbnail`, `kCGImageDestinationOptimizeColorForSharing` (converts to sRGB + strips profile for web), `kCGImageDestinationOrientation`, `kCGImageDestinationMetadata`/`MergeMetadata`, `kCGImageDestinationBackgroundColor` (flatten alpha for JPEG), plus a full HDR gain-map export suite (`kCGImageDestinationEncodeToISOHDR`, `…PreserveGainMap`, `…EncodeToSDR`, `…EncodeTonemapMode`) — relevant if you want to keep or flatten screenshot HDR.

**Metadata preservation vs stripping:**
- **Preserve everything (incl. re-encode):** use `CGImageDestinationAddImageFromSource(dst, source, 0, nil)` — copies image + all metadata from the original source. Or `CGImageDestinationCopyImageSource` to rewrite metadata *without* re-encoding pixels (lossless metadata edit).
- **Strip:** the two `…ShouldExclude…` keys above, or simply `AddImage` (a bare `CGImage` carries no EXIF) — metadata is only added if you pass it.
- **EXIF orientation:** honour it on read (`CGImagePropertyOrientation`) or bake it via `kCGImageDestinationOrientation` on write; screenshots are always orientation 1 so usually a non-issue.
- **DPI:** set `kCGImagePropertyDPIWidth/Height`; screenshots on Retina should record 144 dpi if you want "actual size" print correctness.

**PDF export — two routes:**
- *Single image → PDF:* the `CGImageDestination` with `com.adobe.pdf` above. Simplest.
- *Vector/multi-page or annotations-as-vectors:* `CGContext(consumer:mediaBox:auxiliaryInfo:)` via `CGPDFContext` — `beginPDFPage`/`endPDFPage`, draw the image + your annotation `CGPath`s as real vectors (crisp at any zoom), `closePDF`. Prefer this if annotations should stay vector in the PDF.

---

# 6. Resize / transform

**High-quality resampling — two options, pick by context:**

| Route | When | How |
|---|---|---|
| `CGContext` interpolation | one-off save/export, simplest | `ctx.interpolationQuality = .high` then `draw(cg, in: rect)`. `.high` is bicubic-ish, good enough for downscale. |
| **`CILanczosScaleTransform`** | best quality, esp. large downscale, in a CI pipeline | `scale`, `aspectRatio`. Lanczos = sharpest downsample, the pro default. |
| `CIBicubicScaleTransform` | tunable bicubic (control ringing) | `scale`, `aspectRatio`, `parameterB`, `parameterC` (Mitchell-Netravali knobs) |
| `CIContext` + `kCIContextHighQualityDownsample: true` | any CI render that downsamples | context-level flag, applies to the whole pipeline |

```swift
let f = CIFilter.lanczosScaleTransform()
f.inputImage = CIImage(cgImage: cg)
f.scale = Float(targetH) / Float(cg.height)
f.aspectRatio = 1.0
let small = ctx.createCGImage(f.outputImage!, from: f.outputImage!.extent)
```

**Rotate / flip / straighten:**
- Arbitrary angle: `CIImage.transformed(by: CGAffineTransform(rotationAngle:))`, or `.straightenFilter()` (`angle`) which rotates **and** re-crops to fill (great for a "level horizon" slider).
- 90°/180° + flips: `CIImage.oriented(_: CGImagePropertyOrientation)` — lossless, sets orientation flag, no resample. Cheapest.
- Flip: `CGAffineTransform(scaleX: -1, y: 1)` then translate back into extent.

**Canvas resize (extend the canvas, not the image):** there's no single API — draw the existing image into a larger `CGContext`/`CIImage` at an offset over a `CIConstantColorGenerator` (or transparent) background. `CIAffineClamp` before a blur if you need edge-extend. For "crop" just `CIImage.cropped(to: rect)` or `cg.cropping(to:)`.

---

# 7. Video — burn annotations, crop/rotate, grab frames

## 7a. Burn annotation overlays into an exported video

The Apple-blessed offline path: **`AVMutableVideoComposition` + `AVVideoCompositionCoreAnimationTool`**. You put your annotations in a **`CALayer`** tree and hand it to the tool; the exporter composites video frames into a designated `videoLayer` and renders your overlay layers on top, per frame.

```swift
let comp = AVMutableComposition()
// … add the source video/audio tracks to `comp` …

let videoSize = try await track.load(.naturalSize)
let videoLayer = CALayer(); videoLayer.frame = CGRect(origin: .zero, size: videoSize)
let overlay    = CALayer(); overlay.frame    = videoLayer.frame          // your arrows/text/blur boxes
let parent     = CALayer(); parent.frame     = videoLayer.frame
parent.addSublayer(videoLayer)                                            // video goes UNDER
parent.addSublayer(overlay)                                              // annotations OVER

let vc = AVMutableVideoComposition(propertiesOf: comp)                    // fills renderSize/frameDuration/instructions
vc.animationTool = AVVideoCompositionCoreAnimationTool(
    postProcessingAsVideoLayer: videoLayer, in: parent)                   // verified factory

let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
export.videoComposition = vc                                             // verified property
export.outputFileType = .mov
export.outputURL = outURL
await export.export()                                                    // or exportAsynchronously
```

**Gotchas (these are the ones that cost hours):**
- `AVVideoCompositionCoreAnimationTool` is **offline-render only** (AVAssetExportSession / AVAssetReader). It does **NOT** work with `AVPlayer` — for live preview overlay, add an `AVSynchronizedLayer` or just overlay a normal AppKit view on the player and only composite at export.
- **Core Animation is Y-flipped** vs video. Set `layer.isGeometryFlipped = true` on the overlay, or your annotations render upside-down.
- **Disable implicit animations** on the CALayers (`CATransaction` with `setDisableActions(true)`, or `layer.actions = ["contents": NSNull(), …]`) — otherwise contents fade/animate during render.
- **Animated overlays** must use `CAKeyframeAnimation` with `beginTime = AVCoreAnimationBeginTimeAtZero` (never 0 — 0 means "now" and won't render), and set `animation.isRemovedOnCompletion = false`, `fillMode = .both`.
- For **per-track** overlays instead of a global one, use `videoCompositionCoreAnimationToolWithAdditionalLayer:asTrackID:` and reference that trackID from a composition instruction (advanced; the postProcessing form covers 95% of cases).
- `renderSize` on the composition governs output resolution; `renderScale` should be 1.0 (Retina handled by pixel dims, not scale).

## 7b. Crop / rotate video spatially

Spatial edits live on the composition's per-instruction **layer instructions**, via `AVMutableVideoCompositionLayerInstruction.setTransform(_:at:)` plus the composition's `renderSize`:

- **Crop:** set `vc.renderSize` to the crop size and apply a `CGAffineTransform` translation on the layer instruction to slide the wanted region into frame. (There's no `cropRect` property — cropping = smaller renderSize + translate.)
- **Rotate:** `setTransform(CGAffineTransform(rotationAngle:).concatenating(translation), at: .zero)`. Remember to translate after rotating so the frame lands in `[0, renderSize]`, and swap width/height in `renderSize` for 90°/270°.
- **Scale:** same, a scale transform in the layer instruction.
Build these with `AVMutableVideoComposition` (not `propertiesOf:`) so you control `instructions`, each an `AVMutableVideoCompositionInstruction` with `timeRange` + `[layerInstruction]`.

## 7c. Grab a frame as an image

```swift
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true              // honour rotation metadata
gen.requestedTimeToleranceBefore = .zero               // exact frame (slower)
gen.requestedTimeToleranceAfter  = .zero
// macOS 13+ async single-frame (copyCGImageAtTime is DEPRECATED as of macOS 15):
gen.generateCGImageAsynchronously(for: CMTime(seconds: t, preferredTimescale: 600)) { cg, actual, err in
    // cg: CGImage of that frame
}
// batch: generateCGImagesAsynchronously(forTimes:completionHandler:)
```
Gotchas: exact-frame grabs need **both** tolerances `.zero` (default tolerances snap to the nearest keyframe — you'll get the wrong frame otherwise). If you set a `videoComposition` on the generator, `appliesPreferredTrackTransform` is ignored (the composition's transform wins) — use that to grab a frame *with annotations burned in*.

---

# 8. GPU / perf — CIContext vs CGContext for a live editor

**One `CIContext` for the app's lifetime.** It's the expensive object (compiles kernels, holds GPU/Metal resources). Never create one per render — that's the #1 CI perf mistake.

**Live 60fps canvas (dragging a slider):**
- Render CIImage → a **Metal-backed view** (`MTKView` with a `CIRenderDestination`, or an `NSView` layer-hosting a `CAMetalLayer`), calling `ctx.render(_:to:...)` / `ctx.startTask(toRender:...)` on each frame. **Do not** `createCGImage` every frame — that round-trips GPU→CPU→GPU and tanks framerate.
- Create the context Metal-backed: `CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!)`. It renders on the GPU and can hand results straight to a `CAMetalLayer` drawable with no CPU copy.
- Keep the **source image as a `CIImage` recipe**; only the adjustment parameters change per frame, so the graph is re-fused but the source texture is cached (`kCIContextCacheIntermediates: true`).
- `kCIContextHighQualityDownsample` for the *export* context; you can run the *preview* context without it for speed and switch for final render.

**When CGContext instead:**
- Static compositing/drawing (annotation shapes, text, final flatten) where you're not running filters — `CGContext`/`NSGraphicsContext` is simpler and you control `interpolationQuality`.
- Final export render: `ctx.createCGImage(...)` once, then hand to ImageIO. CPU round-trip is fine for a one-shot save.

**Caching strategy:**
- Cache the decoded source as **one `CIImage`** (lazy, GPU-resident after first render).
- Cache the **segmentation mask** (`CVPixelBuffer`) — it's expensive (a neural model); recompute only when the source image changes, never per slider tick.
- For a heavy filter stack, `img.insertingIntermediate()` (or the context's `cacheIntermediates`) pins expensive mid-graph results so scrubbing one slider doesn't recompute the whole chain.
- Downscale a **preview-resolution** CIImage for the live canvas (e.g. fit-to-view pixels), and only run the full-res graph at export. Users can't see 4K while dragging a slider anyway.
- `render(_:toIOSurface:)` if you need to share the rendered frame with another process/layer zero-copy.

---

# Hard truths — what is NOT possible with public frameworks

1. **No inpainting / content-aware fill / generative object-removal.** Not in Core Image, not in Vision, not in ImagePlayground (that's text→image generation, macOS 26, AI-gated). Photos' "Clean Up" has no API. Best you can ship no-deps: clone stamp, heal brush, median despeckle, segment-and-background-fill. True content-aware fill needs a **bundled Core ML diffusion model** you supply and run yourself.
2. **No mask → vector selection path API.** Vision masks are raster only. Marching-ants requires you to threshold + trace (abuse `VNDetectContoursRequest` on the mask, or draw a shimmer over the alpha edge). No `NSBezierPath` comes for free.
3. **WebP and JPEG-XL are read-only in this SDK.** ImageIO decodes both but **encodes neither**. Exporting them needs a bundled codec. (HEIC and AVIF *do* encode.)
4. **Subject/segmentation edge quality is model-fixed.** Beyond `qualityLevel` (person seg only) there's no public matte-refinement/feather/decontaminate knob. Hair and glass edges are "good phone-camera", not "studio key". Any refinement is your own morphology+blur on the alpha.
5. **`AVVideoCompositionCoreAnimationTool` cannot preview in `AVPlayer`.** Overlay burning is export-time only. Live overlay = a separate AppKit/`AVSynchronizedLayer` path you maintain in parallel with the export layer tree.
6. **No public "auto-enhance" single call for stills.** (`CIImage.autoAdjustmentFilters` exists but is old red-eye/face-era heuristics — underwhelming vs a hand-built exposure/WB/vibrance chain. Not worth wiring as the "magic" button.)
7. **Instance segmentation caps at a handful of subjects** (person-instance up to 4 people; foreground-instance returns "salient" objects, not an unlimited scene parse). It's subject-lifting, not full panoptic segmentation.
8. **Video spatial crop has no `cropRect`.** Cropping is expressed as `renderSize` + a translate transform on a layer instruction — easy to get the maths wrong (off-by-frame, black bars) until you translate *after* rotate/scale and match `renderSize` to the final visible region.
