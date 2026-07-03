import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// One adjustment slider: UI metadata + neutral value. Raw value doubles as
/// the slider tag and the index into ImageAdjustments.values.
enum AdjustParam: Int, CaseIterable {
    case exposure, brightness, contrast, highlights, shadows
    case temperature, tint, saturation, vibrance
    case sharpen

    var label: String {
        switch self {
        case .exposure: return "Exposure"
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .temperature: return "Temperature"
        case .tint: return "Tint"
        case .saturation: return "Saturation"
        case .vibrance: return "Vibrance"
        case .sharpen: return "Sharpen"
        }
    }

    /// Inspector section header this slider lives under.
    var group: String {
        switch self {
        case .exposure, .brightness, .contrast, .highlights, .shadows: return "LIGHT"
        case .temperature, .tint, .saturation, .vibrance: return "COLOUR"
        case .sharpen: return "DETAIL"
        }
    }

    var range: (min: Double, neutral: Double, max: Double) {
        switch self {
        case .exposure: return (-2, 0, 2)
        case .brightness: return (-0.3, 0, 0.3)
        case .contrast: return (0.6, 1, 1.6)
        case .highlights: return (0.3, 1, 1)   // CI only pulls highlights down
        case .shadows: return (-0.7, 0, 0.7)
        case .temperature: return (3500, 6500, 10000)
        case .tint: return (-100, 0, 100)
        case .saturation: return (0, 1, 2)
        case .vibrance: return (-1, 0, 1)
        case .sharpen: return (0, 0, 1.5)
        }
    }
}

/// Curated one-tap looks (plan Phase D): Apple's photo-effect family plus
/// sepia — already tasteful, zero tuning, few and good. Applied UNDER the
/// sliders, so light/colour tweaks ride on top of the look.
enum EffectPreset: String, CaseIterable {
    case mono, tonal, noir, fade, chrome, instant, sepia

    var label: String {
        switch self {
        case .mono: return "Mono"
        case .tonal: return "Tonal"
        case .noir: return "Noir"
        case .fade: return "Fade"
        case .chrome: return "Chrome"
        case .instant: return "Instant"
        case .sepia: return "Sepia"
        }
    }

    func apply(to image: CIImage) -> CIImage {
        if self == .sepia {
            let f = CIFilter.sepiaTone()
            f.inputImage = image
            f.intensity = 0.7
            return f.outputImage ?? image
        }
        return image.applyingFilter("CIPhotoEffect\(label)")
    }
}

/// Parametric adjustment stack. Lives on the canvas ONLY while the user is
/// dragging sliders — it bakes into a new base image on save/export or before
/// any pixel-destructive op (plan invariant 3: the project file never carries
/// a live adjustment stack).
struct ImageAdjustments: Equatable {
    var values: [CGFloat] = AdjustParam.allCases.map { CGFloat($0.range.neutral) }
    var effect: EffectPreset?

    subscript(_ p: AdjustParam) -> CGFloat {
        get { values[p.rawValue] }
        set { values[p.rawValue] = newValue }
    }

    var isIdentity: Bool {
        effect == nil
            && AdjustParam.allCases.allSatisfy { abs(self[$0] - CGFloat($0.range.neutral)) < 0.0001 }
    }

    /// Hand-built auto-enhance: histogram stretch plus a gentle colour pop,
    /// returned as ordinary slider values — the inspector shows exactly what
    /// auto did and every choice stays tweakable. (CIImage's
    /// autoAdjustmentFilters is face/red-eye-era and near-invisible on
    /// screenshots — research hard truth 6.)
    static func auto(for image: CGImage) -> ImageAdjustments {
        var a = ImageAdjustments()
        // 64x64 downsample — we need statistics, not pixels.
        let side = 64
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &px, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return a }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var lumas: [Double] = []
        lumas.reserveCapacity(side * side)
        var saturationSum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            guard px[i + 3] > 128 else { continue }   // skip transparent margin
            let r = Double(px[i]) / 255
            let g = Double(px[i + 1]) / 255
            let b = Double(px[i + 2]) / 255
            lumas.append(0.299 * r + 0.587 * g + 0.114 * b)
            let mx = max(r, g, b)
            saturationSum += mx > 0 ? (mx - min(r, g, b)) / mx : 0
        }
        guard lumas.count > 16 else { return a }
        lumas.sort()
        func percentile(_ p: Double) -> Double {
            lumas[min(Int(p * Double(lumas.count - 1)), lumas.count - 1)]
        }
        let p2 = percentile(0.02)
        let p50 = percentile(0.5)
        let p98 = percentile(0.98)

        // Flat/hazy tones stretch toward full range; crisp screenshots
        // (near-full range already) stay untouched.
        let range = p98 - p2
        if range > 0.05, range < 0.82 {
            a[.contrast] = CGFloat(min(1 + (0.82 - range) * 0.9, 1.3))
        }
        // Re-centre the mid-tones, gently — ignore sub-visible nudges so
        // reset dots don't light up for nothing.
        let shift = (0.5 - (p2 + p98) / 2) * 0.25
        if abs(shift) >= 0.015 {
            a[.brightness] = CGFloat(max(-0.08, min(0.08, shift)))
        }
        // Dark-heavy image: lift the shadows.
        if p50 < 0.35 {
            a[.shadows] = CGFloat(min((0.35 - p50) * 1.2, 0.35))
        }
        // Muted (but not greyscale) colours: a touch of vibrance.
        let meanSaturation = saturationSum / Double(lumas.count)
        if meanSaturation > 0.02, meanSaturation < 0.3 {
            a[.vibrance] = CGFloat(min((0.3 - meanSaturation) * 1.2, 0.3))
        }
        return a
    }

    /// The CIImage recipe — the whole chain fuses into one GPU pass at render.
    func ciImage(from input: CIImage) -> CIImage {
        var img = effect?.apply(to: input) ?? input
        func on(_ p: AdjustParam) -> Bool {
            abs(self[p] - CGFloat(p.range.neutral)) >= 0.0001
        }
        if on(.exposure) {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(self[.exposure])
            img = f.outputImage ?? img
        }
        if on(.brightness) || on(.contrast) || on(.saturation) {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.brightness = Float(self[.brightness])
            f.contrast = Float(self[.contrast])
            f.saturation = Float(self[.saturation])
            img = f.outputImage ?? img
        }
        if on(.highlights) || on(.shadows) {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img
            f.highlightAmount = Float(self[.highlights])
            f.shadowAmount = Float(self[.shadows])
            f.radius = 2.5
            img = f.outputImage ?? img
        }
        if on(.temperature) || on(.tint) {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            // Slider value goes in as the scene illuminant being corrected
            // AWAY from — probe-verified: putting it in targetNeutral runs
            // the slider backwards (right would cool instead of warm).
            f.neutral = CIVector(x: self[.temperature], y: self[.tint])
            f.targetNeutral = CIVector(x: 6500, y: 0)
            img = f.outputImage ?? img
        }
        if on(.vibrance) {
            let f = CIFilter.vibrance()
            f.inputImage = img
            f.amount = Float(self[.vibrance])
            img = f.outputImage ?? img
        }
        if on(.sharpen) {
            let f = CIFilter.unsharpMask()
            f.inputImage = img
            f.radius = 2.5
            f.intensity = Float(self[.sharpen])
            img = f.outputImage ?? img
        }
        return img
    }

    /// Full-res render through the app's one CIContext. Identity returns the
    /// input untouched (no needless GPU round-trip).
    func apply(to cg: CGImage) -> CGImage? {
        guard !isIdentity else { return cg }
        let input = CIImage(cgImage: cg)
        // Crop: unsharp/shadow filters pad the extent; the bake must keep
        // the original pixel dimensions.
        return ImagePipeline.ciContext.createCGImage(
            ciImage(from: input).cropped(to: input.extent), from: input.extent)
    }
}
