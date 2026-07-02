@preconcurrency import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// SCStream → AVAssetWriter recording engine. Exists for one reason
/// SCRecordingOutput can't do: pause/resume. Pausing drops buffers; resuming
/// measures the wall-clock hole and subtracts it from every later timestamp,
/// so the file plays as one continuous take.
///
/// All mutable state is confined to `queue` — the same queue SCK delivers
/// sample buffers on. Main-actor callers talk to it only via setPaused /
/// finish / elapsedSeconds.
final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "recording-writer", qos: .userInitiated)

    /// Fired once, on the writer queue, when the first frame lands.
    var onStarted: (@Sendable () -> Void)?
    /// Fired on the writer queue if the writer dies mid-recording.
    var onFailed: (@Sendable (Error) -> Void)?

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let micInput: AVAssetWriterInput?
    private let frameDuration: CMTime

    // Queue-confined.
    private var sessionStarted = false
    private var sessionStart = CMTime.zero
    private var paused = false
    /// Set while paused; the first video frame after resume rebases `offset`.
    private var awaitingRebase = false
    private var offset = CMTime.zero
    private var lastRawVideoPTS = CMTime.invalid
    private var finished = false
    private var startedSignalled = false

    private let elapsedLock = NSLock()
    private var _elapsedSeconds: Double = 0
    /// Appended (non-paused) duration — safe to read from any thread.
    var elapsedSeconds: Double {
        elapsedLock.lock()
        defer { elapsedLock.unlock() }
        return _elapsedSeconds
    }

    init(
        url: URL, width: Int, height: Int, fps: Int,
        systemAudio: Bool, microphone: Bool
    ) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))

        // ~4 bits/pixel at recording fps, clamped to sane bounds — matches
        // SCRecordingOutput's quality class for screen content.
        let bitrate = min(30_000_000, max(4_000_000, width * height * 4))
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        func makeAudioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        // System audio and mic stay separate tracks, like SCRecordingOutput.
        if systemAudio {
            let input = makeAudioInput()
            writer.add(input)
            systemAudioInput = input
        } else {
            systemAudioInput = nil
        }
        if microphone {
            let input = makeAudioInput()
            writer.add(input)
            micInput = input
        } else {
            micInput = nil
        }
        super.init()
    }

    // MARK: Control (any thread)

    func setPaused(_ value: Bool) {
        queue.async {
            guard !self.finished, self.paused != value else { return }
            self.paused = value
            if !value { self.awaitingRebase = true }
        }
    }

    /// Finalises the file. Returns the recorded (non-paused) duration.
    func finish() async throws -> Double {
        // Drain the queue so no append races the markAsFinished calls.
        let hadSession = await withCheckedContinuation { continuation in
            queue.async {
                let had = self.sessionStarted && !self.finished
                self.finished = true
                if had {
                    self.videoInput.markAsFinished()
                    self.systemAudioInput?.markAsFinished()
                    self.micInput?.markAsFinished()
                }
                continuation.resume(returning: self.sessionStarted)
            }
        }
        guard hadSession else {
            writer.cancelWriting()
            throw NSError(domain: "RecordingWriter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Recording produced no frames"])
        }
        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? NSError(domain: "RecordingWriter", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not finalise the recording"])
        }
        return elapsedSeconds
    }

    // MARK: SCStreamOutput (arrives on `queue`)

    func stream(
        _ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard !finished, buffer.isValid else { return }
        switch type {
        case .screen: handleVideo(buffer)
        case .audio: handleAudio(buffer, input: systemAudioInput)
        case .microphone: handleAudio(buffer, input: micInput)
        @unknown default: break
        }
    }

    // MARK: Video

    private func handleVideo(_ buffer: CMSampleBuffer) {
        // Idle/blank repeats carry bogus timing — only complete frames count.
        guard frameStatus(buffer) == .complete else { return }
        if paused { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)

        if !sessionStarted {
            guard writer.startWriting() else {
                fail(writer.error)
                return
            }
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
            sessionStarted = true
        }
        if awaitingRebase, lastRawVideoPTS.isValid {
            // The pause hole = raw gap minus one nominal frame step.
            let gap = pts - lastRawVideoPTS - frameDuration
            if gap > .zero { offset = offset + gap }
            awaitingRebase = false
        }
        lastRawVideoPTS = pts

        guard videoInput.isReadyForMoreMediaData,
              let retimed = retimed(buffer) else { return }
        guard videoInput.append(retimed) else {
            fail(writer.error)
            return
        }
        if !startedSignalled {
            startedSignalled = true
            onStarted?()
        }
        let elapsed = (pts - offset - sessionStart).seconds
        if elapsed.isFinite {
            elapsedLock.lock()
            _elapsedSeconds = elapsed
            elapsedLock.unlock()
        }
    }

    // MARK: Audio

    private func handleAudio(_ buffer: CMSampleBuffer, input: AVAssetWriterInput?) {
        // Audio holds until the first post-resume video frame fixes the offset,
        // so both tracks rebase by the same amount.
        guard let input, sessionStarted, !paused, !awaitingRebase else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts - offset >= sessionStart else { return }
        guard input.isReadyForMoreMediaData, let retimed = retimed(buffer) else { return }
        if !input.append(retimed) {
            fail(writer.error)
        }
    }

    // MARK: Helpers

    private func fail(_ error: Error?) {
        guard !finished else { return }
        finished = true
        onFailed?(error ?? NSError(domain: "RecordingWriter", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Recording writer failed"]))
    }

    private func frameStatus(_ buffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(
                  buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    /// Copy of the buffer with every timestamp shifted back by `offset`.
    private func retimed(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard offset != .zero else { return buffer }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in 0..<count {
            infos[i].presentationTimeStamp = infos[i].presentationTimeStamp - offset
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = infos[i].decodeTimeStamp - offset
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: buffer,
            sampleTimingEntryCount: count, sampleTimingArray: &infos,
            sampleBufferOut: &out)
        return out
    }
}
