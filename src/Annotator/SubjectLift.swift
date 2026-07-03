import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// The one Core Image context for editor pixel work (research §8: contexts
/// compile kernels and hold GPU state — create once, reuse for the app's
/// lifetime). Adjustment phases build on this same context.
enum ImagePipeline {
    static let ciContext = CIContext(options: [.cacheIntermediates: true])
}

/// Subject lifting + background removal on Vision's foreground-instance model
/// (research §1a). One engine per canvas; the observation is computed once per
/// base image and reused for hover previews, click-to-lift and remove-bg.
@MainActor
final class SubjectLiftEngine {
    enum Phase: Equatable {
        case idle, analysing, ready, failed
    }

    private(set) var phase: Phase = .idle
    private var handler: ImageRequestHandler?
    private var observation: InstanceMaskObservation?
    private var analysedBase: CGImage?
    private var task: Task<Void, Never>?

    /// Analysis finished (ready or failed) — the canvas refreshes hover state.
    var onSettled: (() -> Void)?

    /// One lifted subject: the RGBA cut-out plus everything needed to re-cut
    /// it at a different feather without re-running the model.
    struct Lift {
        let image: CGImage
        /// Where the subject sits, in image points (top-left origin).
        let rectPoints: CGRect
        let source: CGImage
        let mask: CIImage
        /// Crop rect in Core Image (bottom-left) pixel coordinates.
        let cropPx: CGRect
    }

    /// Idempotent: analyses `base` unless it is already analysed/analysing.
    func prepare(base: CGImage) {
        if base !== analysedBase { invalidate() }
        guard phase == .idle else { return }
        phase = .analysing
        analysedBase = base
        let h = ImageRequestHandler(base)
        handler = h
        task = Task { [weak self] in
            var obs: InstanceMaskObservation?
            do {
                obs = try await h.perform(GenerateForegroundInstanceMaskRequest())
            } catch {
                NSLog("subject lift analysis failed: \(error)")
            }
            guard let self, !Task.isCancelled else { return }
            observation = obs
            phase = obs == nil ? .failed : .ready
            onSettled?()
        }
    }

    func invalidate() {
        task?.cancel()
        task = nil
        handler = nil
        observation = nil
        analysedBase = nil
        phase = .idle
    }

    private func ensureReady(base: CGImage) async -> Bool {
        prepare(base: base)
        await task?.value
        return phase == .ready
    }

    /// Instance indices under an image-point (top-left origin) location.
    /// Empty when the point is on the background (instanceAtPoint reports
    /// the background as label 0 — verified by probe, not "no result").
    func instances(atImagePoint p: CGPoint, imageSize: NSSize) -> IndexSet {
        guard let observation, imageSize.width > 0, imageSize.height > 0 else { return [] }
        return observation.instanceAtPoint(NormalizedPoint(
            x: p.x / imageSize.width,
            y: 1 - p.y / imageSize.height))   // Vision is bottom-left normalised
            .intersection(observation.allInstances)
    }

    /// Amber hover tint for the given instances — analysis-resolution, drawn
    /// stretched over the whole image (soft edges are fine for a preview).
    func hoverOverlay(for instances: IndexSet) -> CGImage? {
        guard let observation, !instances.isEmpty,
              let buffer = try? observation.generateMask(for: instances) else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        let amber = CIImage(color: CIColor(cgColor: HUDStyle.accent.withAlphaComponent(0.5).cgColor))
            .cropped(to: mask.extent)
        guard let tinted = Self.masked(amber, with: mask) else { return nil }
        return ImagePipeline.ciContext.createCGImage(tinted, from: mask.extent)
    }

    /// Cut the given instances out of `base` as a tight-cropped RGBA image.
    func lift(instances: IndexSet, base: CGImage, scale: CGFloat) -> Lift? {
        guard let observation, let handler,
              let lowRes = try? observation.generateMask(for: instances),
              let bounds = Self.maskBounds(lowRes),
              let scaled = try? observation.generateScaledMask(
                  for: instances, scaledToImageFrom: handler)
        else { return nil }
        let w = CGFloat(base.width)
        let h = CGFloat(base.height)
        let pad: CGFloat = 6   // soft mask edges bleed slightly past the 0.5 contour
        let rectPx = CGRect(
            x: bounds.minX * w - pad, y: bounds.minY * h - pad,
            width: bounds.width * w + pad * 2, height: bounds.height * h + pad * 2
        ).intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard !rectPx.isEmpty else { return nil }
        let cropPx = CGRect(
            x: rectPx.minX, y: h - rectPx.maxY, width: rectPx.width, height: rectPx.height)
        let mask = CIImage(cvPixelBuffer: scaled)
        guard let cut = Self.cutout(source: base, mask: mask, cropPx: cropPx, feather: 0)
        else { return nil }
        return Lift(
            image: cut,
            rectPoints: CGRect(
                x: rectPx.minX / scale, y: rectPx.minY / scale,
                width: rectPx.width / scale, height: rectPx.height / scale),
            source: base, mask: mask, cropPx: cropPx)
    }

    /// Full-frame subject matte: everything Vision calls foreground stays,
    /// the rest goes transparent. That IS "remove background" (research §2).
    func removeBackgroundImage(from base: CGImage) async -> CGImage? {
        guard await ensureReady(base: base), let observation, let handler else { return nil }
        let all = observation.allInstances
        guard !all.isEmpty,
              let scaled = try? observation.generateScaledMask(
                  for: all, scaledToImageFrom: handler) else { return nil }
        return Self.cutout(
            source: base, mask: CIImage(cvPixelBuffer: scaled),
            cropPx: CGRect(x: 0, y: 0, width: base.width, height: base.height), feather: 0)
    }

    // MARK: Core Image plumbing

    /// source × mask → transparent-background cut-out, cropped to `cropPx`.
    /// `feather` is a gaussian sigma (image pixels) applied to the mask —
    /// the shared edge-softness knob for every mask feature (plan invariant 7).
    static func cutout(
        source: CGImage, mask: CIImage, cropPx: CGRect, feather: CGFloat
    ) -> CGImage? {
        var m = mask
        if feather > 0 {
            m = m.clampedToExtent().applyingGaussianBlur(sigma: feather).cropped(to: mask.extent)
        }
        guard let out = masked(CIImage(cgImage: source), with: m) else { return nil }
        return ImagePipeline.ciContext.createCGImage(out, from: cropPx)
    }

    private static func masked(_ input: CIImage, with mask: CIImage) -> CIImage? {
        let blend = CIFilter.blendWithMask()
        blend.inputImage = input
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask
        return blend.outputImage
    }

    /// Bounding box of mask coverage (> 0.5), normalised with TOP-LEFT origin
    /// (pixel buffers are top-row-first). Vision has no mask→bbox API; the
    /// analysis-resolution buffer is small enough to scan on the CPU.
    private static func maskBounds(_ buffer: CVPixelBuffer) -> CGRect? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<w where row[x] > 0.5 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
            width: CGFloat(maxX - minX + 1) / CGFloat(w),
            height: CGFloat(maxY - minY + 1) / CGFloat(h))
    }
}

/// Cheap transparency probe: draw downsampled into a tiny bitmap and check
/// alphas — O(1) regardless of source size (a scrolling composite can be
/// 300 MP; scanning it per open is not on). Downsampling averages alpha, so
/// any real transparent region survives the shrink.
func imageLooksTransparent(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast:
        return false
    default:
        break
    }
    let side = 32
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard let ctx = CGContext(
        data: &pixels, width: side, height: side,
        bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    ctx.interpolationQuality = .low
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] < 250 {
        return true
    }
    return false
}
