import AVFoundation
import ScreenCaptureKit

/// 모든 가변 상태는 queue에서만 접근한다. ScreenCaptureKit 콜백도 같은 큐를 사용한다.
final class VideoFrameWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.goldenrabbit.ohmyopensnap.video-writer")
    private let outputURL: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var didStartSession = false
    private var isStopping = false
    private var isPaused = false
    private var pauseBeganAt: CMTime?
    private var pausedDuration: CMTime = .zero
    private var shouldClosePauseGap = false
    private var failure: Error?

    init(outputURL: URL) { self.outputURL = outputURL }

    func start(width: Int, height: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try FileManager.default.createDirectory(at: self.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let writer = try AVAssetWriter(outputURL: self.outputURL, fileType: .mp4)
                    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: width, AVVideoHeightKey: height
                    ])
                    input.expectsMediaDataInRealTime = true
                    guard writer.canAdd(input) else { throw RecordingError.writeFailed }
                    writer.add(input)
                    guard writer.startWriting() else { throw writer.error ?? RecordingError.writeFailed }
                    self.writer = writer
                    self.input = input
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.isStopping = true
                self.writer?.cancelWriting()
                self.writer = nil
                self.input = nil
                try? FileManager.default.removeItem(at: self.outputURL)
                continuation.resume()
            }
        }
    }

    func finish(streamError: Error?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.isStopping = true
                guard let writer = self.writer, let input = self.input else {
                    continuation.resume(throwing: RecordingError.writeFailed)
                    return
                }
                VideoWriterFinalizer.finish(writer: writer, input: input, hasFrames: self.didStartSession,
                                            failure: self.failure ?? streamError) { result in
                    self.queue.async {
                        self.writer = nil
                        self.input = nil
                        continuation.resume(with: result)
                    }
                }
            }
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async {
            guard !self.isStopping, self.isPaused != paused else { return }
            self.isPaused = paused
            if paused { self.pauseBeganAt = nil }
            else { self.shouldClosePauseGap = true }
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isStopping, failure == nil, sampleBuffer.isValid, isCompleteFrame(sampleBuffer),
              let writer, let input else { return }
        guard writer.status == .writing else {
            failure = writer.error ?? RecordingError.writeFailed
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if isPaused {
            if pauseBeganAt == nil { pauseBeganAt = presentationTime }
            return
        }
        if shouldClosePauseGap {
            if let pauseBeganAt {
                pausedDuration = CMTimeAdd(pausedDuration, CMTimeSubtract(presentationTime, pauseBeganAt))
            }
            pauseBeganAt = nil
            shouldClosePauseGap = false
        }
        guard input.isReadyForMoreMediaData else { return }
        let adjustedTime = CMTimeSubtract(presentationTime, pausedDuration)
        guard let adjusted = retimedSampleBuffer(sampleBuffer, presentationTime: adjustedTime) else {
            failure = RecordingError.writeFailed
            return
        }
        if !didStartSession {
            writer.startSession(atSourceTime: adjustedTime)
            didStartSession = true
        }
        if !input.append(adjusted) { failure = writer.error ?? RecordingError.writeFailed }
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }
        return status == .complete
    }

    private func retimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer))
        var adjusted: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                           sampleBuffer: sampleBuffer,
                                                           sampleTimingEntryCount: 1,
                                                           sampleTimingArray: &timing,
                                                           sampleBufferOut: &adjusted)
        guard status == noErr else { return nil }
        return adjusted
    }
}
