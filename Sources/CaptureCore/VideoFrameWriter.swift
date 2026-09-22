import AVFoundation
import ScreenCaptureKit

/// 녹화 출력 크기와 코덱. 크기는 항상 짝수다.
/// H.264 레벨 5.2 한계(4096×2304)를 넘는 영역(5K 전체 화면 등)은 HEVC로 인코딩하고,
/// HEVC 한계(8192×4320)마저 넘으면 비율을 유지해 줄인다. 세로 화면도 같은 기준으로 긴 변/짧은 변을 비교한다.
struct VideoOutputFormat: Equatable {
    static let h264Limit = (long: 4096, short: 2304)
    static let hevcLimit = (long: 8192, short: 4320)

    let width: Int
    let height: Int
    let codec: AVVideoCodecType

    init(pixelWidth: CGFloat, pixelHeight: CGFloat) {
        let w = max(2, pixelWidth.rounded()), h = max(2, pixelHeight.rounded())
        let fit = min(1, CGFloat(Self.hevcLimit.long) / max(w, h), CGFloat(Self.hevcLimit.short) / min(w, h))
        width = max(2, Int((w * fit).rounded(.down)) / 2 * 2)
        height = max(2, Int((h * fit).rounded(.down)) / 2 * 2)
        let fitsH264 = max(width, height) <= Self.h264Limit.long && min(width, height) <= Self.h264Limit.short
        codec = fitsH264 ? .h264 : .hevc
    }
}

/// 모든 가변 상태는 queue에서만 접근한다. ScreenCaptureKit 콜백도 같은 큐를 사용한다.
/// 일시정지·중지 시각은 프레임 PTS가 아니라 호스트 시계로 잰다. ScreenCaptureKit은 화면이 바뀔 때만
/// 완성 프레임을 보내므로, 정지 화면에서는 다음 프레임이 언제 올지 알 수 없다.
final class VideoFrameWriter: @unchecked Sendable {
    typealias Clock = @Sendable () -> CMTime
    /// ScreenCaptureKit 샘플 PTS와 같은 시계.
    static let hostClock: Clock = { CMClockGetTime(CMClockGetHostTimeClock()) }
    /// 길이 정보가 없는 샘플의 최소 표시 길이.
    private static let minimumFrameDuration = CMTime(value: 1, timescale: 60)

    let queue = DispatchQueue(label: "com.goldenrabbit.ohmyopensnap.video-writer")
    private let outputURL: URL
    private let clock: Clock
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var didStartSession = false
    private var isStopping = false
    /// nil이 아니면 일시정지 중이다.
    private var pauseBeganAt: CMTime?
    private var resumedAt: CMTime?
    private var pausedDuration: CMTime = .zero
    private var stopRequestedAt: CMTime?
    private var lastAppendedTime: CMTime?
    private var lastFrameEnd: CMTime?
    private var failure: Error?

    init(outputURL: URL, clock: @escaping Clock = VideoFrameWriter.hostClock) {
        self.outputURL = outputURL
        self.clock = clock
    }

    func start(width: Int, height: Int, codec: AVVideoCodecType = .h264) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try FileManager.default.createDirectory(at: self.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let writer = try AVAssetWriter(outputURL: self.outputURL, fileType: .mp4)
                    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                        AVVideoCodecKey: codec,
                        AVVideoWidthKey: width, AVVideoHeightKey: height
                    ])
                    input.expectsMediaDataInRealTime = true
                    guard writer.canAdd(input) else { throw RecordingError.writeFailed }
                    writer.add(input)
                    guard writer.startWriting() else {
                        // 실패한 writer가 남긴 빈 파일이 보관함에 깨진 항목으로 보이지 않게 한다.
                        try? FileManager.default.removeItem(at: self.outputURL)
                        throw writer.error ?? RecordingError.writeFailed
                    }
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

    /// 중지 요청(사용자 중지·시스템의 공유 중단) 시각을 기록한다. 영상은 이 시각까지 이어지고 이후에 찍힌 프레임은 버린다.
    func markStopRequested() {
        let now = clock()
        queue.async {
            if self.stopRequestedAt == nil { self.stopRequestedAt = now }
        }
    }

    /// `streamError`는 파일을 완성하지 못했을 때의 원인으로만 쓴다. 프레임이 담긴 파일이 완성되면 성공이다.
    func finish(streamError: Error?) async throws {
        let now = clock()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.isStopping = true
                guard let writer = self.writer, let input = self.input else {
                    continuation.resume(throwing: RecordingError.writeFailed)
                    return
                }
                if let streamError { NSLog("Recording stream stopped: \(streamError)") }
                let endTime = self.lastFrameEnd.map {
                    Self.sessionEndTime(stopTime: self.stopRequestedAt ?? now, pauseBeganAt: self.pauseBeganAt,
                                        pausedDuration: self.pausedDuration, lastFrameEnd: $0)
                }
                VideoWriterFinalizer.finish(writer: writer, input: input, hasFrames: self.didStartSession,
                                            endTime: endTime, failure: self.failure ?? streamError) { result in
                    self.queue.async {
                        self.writer = nil
                        self.input = nil
                        continuation.resume(with: result)
                    }
                }
            }
        }
    }

    /// 보정된 타임라인의 영상 끝 시각. 화면이 멈춰 프레임이 오지 않은 마지막 구간도 중지 시각까지 남긴다.
    /// 일시정지 중에 멈췄다면 일시정지를 누른 시각에서 끝낸다. 마지막 프레임의 끝보다 앞서지 않는다.
    static func sessionEndTime(stopTime: CMTime, pauseBeganAt: CMTime?, pausedDuration: CMTime,
                               lastFrameEnd: CMTime) -> CMTime {
        let stop = pauseBeganAt.map { CMTimeMinimum($0, stopTime) } ?? stopTime
        return CMTimeMaximum(CMTimeSubtract(stop, pausedDuration), lastFrameEnd)
    }

    func setPaused(_ paused: Bool) {
        // 누른 순간의 시각. 정지 화면에서는 일시정지 중 프레임이 오지 않으므로 프레임 PTS로는 잴 수 없다.
        let now = clock()
        queue.async {
            guard !self.isStopping, (self.pauseBeganAt != nil) != paused else { return }
            if paused {
                self.pauseBeganAt = now
            } else if let pauseBeganAt = self.pauseBeganAt {
                let gap = CMTimeSubtract(now, pauseBeganAt)
                if gap > .zero { self.pausedDuration = CMTimeAdd(self.pausedDuration, gap) }
                self.pauseBeganAt = nil
                self.resumedAt = now
            }
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
        // 중지 이후나 일시정지 구간 안에서 찍힌 프레임은 버린다.
        if let stopRequestedAt, presentationTime >= stopRequestedAt { return }
        if let pauseBeganAt, presentationTime >= pauseBeganAt { return }
        if let resumedAt, presentationTime < resumedAt { return }
        guard input.isReadyForMoreMediaData else { return }
        let adjustedTime = CMTimeSubtract(presentationTime, pausedDuration)
        // 늦게 도착한 프레임이 시간을 거슬러 append 실패로 writer를 망가뜨리지 않게 한다.
        if let lastAppendedTime, adjustedTime <= lastAppendedTime { return }
        guard let adjusted = retimedSampleBuffer(sampleBuffer, presentationTime: adjustedTime) else {
            failure = RecordingError.writeFailed
            return
        }
        if !didStartSession {
            writer.startSession(atSourceTime: adjustedTime)
            didStartSession = true
        }
        guard input.append(adjusted) else {
            failure = writer.error ?? RecordingError.writeFailed
            return
        }
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        lastAppendedTime = adjustedTime
        lastFrameEnd = CMTimeAdd(adjustedTime, duration.isNumeric && duration > .zero ? duration : Self.minimumFrameDuration)
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
