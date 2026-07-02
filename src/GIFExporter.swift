import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts a recorded mp4 into an animated GIF. Returns a temp URL; the
/// caller owns moving it into place (OutputRouter does).
enum GIFExporter {
    enum ExportError: LocalizedError {
        case emptyVideo
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .emptyVideo: return "The recording contains no frames."
            case .writeFailed: return "Could not write the GIF."
            }
        }
    }

    static func export(from videoURL: URL, fps: Int, maxWidth: CGFloat) async throws -> URL {
        // GIF delay resolution is 1/100s and many decoders clamp delays below
        // 0.02s to 0.1s — cap at 50fps so the requested pacing survives.
        let fps = max(1, min(fps, 50))

        let asset = AVURLAsset(url: videoURL)
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw ExportError.emptyVideo }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)   // fits, keeps aspect
        // Exact-before tolerance: sloppy seeking samples the same sync frame
        // repeatedly and the GIF plays back stuttery.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: CMTimeScale(fps * 2))

        let frameCount = max(1, Int(seconds * Double(fps)))
        let times = (0..<frameCount).map {
            CMTime(value: CMTimeValue($0), timescale: CMTimeScale(fps))
        }
        let delay = 1.0 / Double(fps)

        let gifURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sentry-capture-\(UUID().uuidString).gif")
        guard let destination = CGImageDestinationCreateWithURL(
            gifURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else {
            throw ExportError.writeFailed
        }

        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0,                // 0 = loop forever
            kCGImagePropertyGIFHasGlobalColorMap: true,     // one 256-colour palette, smaller files
        ]] as CFDictionary)
        // Both delay keys: decoders disagree on which one they honour.
        let frameProperties = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay,
            kCGImagePropertyGIFUnclampedDelayTime: delay,
        ]] as CFDictionary

        var written = 0
        for await result in generator.images(for: times) {
            if case .success(_, let image, _) = result {
                CGImageDestinationAddImage(destination, image, frameProperties)
                written += 1
            }
            // Failed frames are skipped silently — one dropped frame beats a
            // failed export.
        }

        guard written > 0, CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: gifURL)
            throw written > 0 ? ExportError.writeFailed : ExportError.emptyVideo
        }
        return gifURL
    }
}
