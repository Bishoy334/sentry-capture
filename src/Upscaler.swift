import AppKit
import CoreML
import CoreVideo

/// Real-ESRGAN 4x upscaler (Phase G, owner-approved bundle). The model is a
/// compiled Core ML package produced by scripts/convert_upscaler.py and
/// bundled by build.sh; everything here degrades to "unavailable" when the
/// bundle lacks it, so builds without the model stay fully functional.
///
/// The network takes fixed 512x512 tiles -> 2048x2048. Large images process
/// as an overlapping tile grid: each tile's outer margin (conv edge
/// artefacts) is discarded except where it touches the image border.
enum Upscaler {
    static let factor = 4
    private static let tile = 512
    private static let overlap = 16

    private static let loadedModel: MLModel? = {
        guard let url = Bundle.main.url(forResource: "Upscaler", withExtension: "mlmodelc")
        else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all   // ANE/GPU where available
        return try? MLModel(contentsOf: url, configuration: config)
    }()

    static var isAvailable: Bool { loadedModel != nil }

    /// 4x the pixels. Synchronous and heavy (seconds on large images) —
    /// call off the main thread.
    static func upscale4x(_ image: CGImage) -> CGImage? {
        guard let model = loadedModel else { return nil }
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        guard let out = CGContext(
            data: nil, width: w * factor, height: h * factor,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        out.interpolationQuality = .none

        // Tiles advance by (tile - 2*overlap); each keeps its interior, with
        // margins surviving only at image borders. Consecutive keep windows
        // butt exactly: next tile's (x + overlap) == this tile's
        // (x + tile - overlap). End tiles clamp back onto the image, so
        // their keep windows only ever widen the coverage.
        let stride = tile - overlap * 2
        var y = 0
        while true {
            let ty = min(y, max(h - tile, 0))
            let keepY0 = ty == 0 ? 0 : ty + overlap
            let keepY1 = ty + tile >= h ? h : ty + tile - overlap
            var x = 0
            while true {
                let tx = min(x, max(w - tile, 0))
                let keepX0 = tx == 0 ? 0 : tx + overlap
                let keepX1 = tx + tile >= w ? w : tx + tile - overlap
                guard keepX1 > keepX0, keepY1 > keepY0,
                      let scaled = upscaleTile(image, model: model, tx: tx, ty: ty),
                      let piece = scaled.cropping(to: CGRect(
                          x: (keepX0 - tx) * factor, y: (keepY0 - ty) * factor,
                          width: (keepX1 - keepX0) * factor,
                          height: (keepY1 - keepY0) * factor))
                else { return nil }
                // CGContext origin bottom-left; the maths above is top-left.
                out.draw(piece, in: CGRect(
                    x: keepX0 * factor, y: (h - keepY1) * factor,
                    width: (keepX1 - keepX0) * factor,
                    height: (keepY1 - keepY0) * factor))
                if tx + tile >= w { break }
                x = tx + stride
            }
            if ty + tile >= h { break }
            y = ty + stride
        }
        return out.makeImage()
    }

    /// One 512-tile at image position (tx, ty), top-left coords. The tile is
    /// drawn from the image; parts past the border stay black and are always
    /// discarded by the caller's keep-rect.
    private static func upscaleTile(
        _ image: CGImage, model: MLModel, tx: Int, ty: Int
    ) -> CGImage? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, tile, tile, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: tile, height: tile, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // Draw so image pixel (tx, ty) lands at the tile's top-left.
        ctx.draw(image, in: CGRect(
            x: -tx, y: tile - image.height + ty,
            width: image.width, height: image.height))

        guard let input = try? MLDictionaryFeatureProvider(
                  dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]),
              let output = try? model.prediction(from: input),
              let outBuffer = output.featureValue(for: "upscaled")?.imageBufferValue
        else { return nil }
        return ImagePipeline.ciContext.createCGImage(
            CIImage(cvPixelBuffer: outBuffer),
            from: CGRect(x: 0, y: 0, width: tile * factor, height: tile * factor))
    }
}
