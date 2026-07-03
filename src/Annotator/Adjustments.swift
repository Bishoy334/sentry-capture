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

/// Parametric adjustment stack. Lives on the canvas ONLY while the user is
/// dragging sliders — it bakes into a new base image on save/export or before
/// any pixel-destructive op (plan invariant 3: the project file never carries
/// a live adjustment stack).
struct ImageAdjustments: Equatable {
    var values: [CGFloat] = AdjustParam.allCases.map { CGFloat($0.range.neutral) }

    subscript(_ p: AdjustParam) -> CGFloat {
        get { values[p.rawValue] }
        set { values[p.rawValue] = newValue }
    }

    var isIdentity: Bool {
        AdjustParam.allCases.allSatisfy { abs(self[$0] - CGFloat($0.range.neutral)) < 0.0001 }
    }

    /// The CIImage recipe — the whole chain fuses into one GPU pass at render.
    func ciImage(from input: CIImage) -> CIImage {
        var img = input
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
