import XCTest
import AVFoundation
import ImageIO

@MainActor
private final class ControlledRecording: Recording {
    var startContinuation: CheckedContinuation<Void, Error>?
    var stopContinuation: CheckedContinuation<URL, Error>?
    var startCount = 0
    var stopCount = 0
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    func start() async throws {
        startCount += 1
        try await withCheckedThrowingContinuation {
            startContinuation = $0
            onStart?()
        }
    }
    func stop() async throws -> URL {
        stopCount += 1
        return try await withCheckedThrowingContinuation {
            stopContinuation = $0
            onStop?()
        }
    }
    func setPaused(_ paused: Bool) {}
}

/// 샘플 PTS와 같은 시간축을 쓰는 가짜 호스트 시계.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(seconds: Double) { value = seconds }
    var seconds: Double {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    var read: VideoFrameWriter.Clock { { [self] in CMTime(seconds: seconds, preferredTimescale: 600) } }
}

final class RecordingTests: XCTestCase {
    @MainActor
    func testTerminationWaitsForStartAndCoalescesStopRequests() async throws {
        let session = RecordingSession()
        let recorder = ControlledRecording()
        let started = expectation(description: "녹화 시작 대기")
        let stopped = expectation(description: "녹화 마무리 대기")
        recorder.onStart = { started.fulfill() }
        recorder.onStop = { stopped.fulfill() }
        let start = Task { try await session.start(recorder) }
        await fulfillment(of: [started], timeout: 2)
        let stop1 = Task { try await session.stop() }
        let stop2 = Task { try await session.stop() }
        recorder.startContinuation?.resume()
        try await start.value
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertTrue(session.isBusy)
        XCTAssertEqual(recorder.stopCount, 1)
        do {
            try await session.start(ControlledRecording())
            XCTFail("저장 중 새 녹화를 시작하면 안 된다")
        } catch {}
        let expected = URL(fileURLWithPath: "/tmp/recorded.mp4")
        recorder.stopContinuation?.resume(returning: expected)
        let first = try await stop1.value
        let second = try await stop2.value
        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected)
        XCTAssertFalse(session.isBusy)
    }

    @MainActor
    func testStartFailureReturnsSessionToIdle() async {
        let session = RecordingSession()
        let recorder = ControlledRecording()
        recorder.onStart = { recorder.startContinuation?.resume(throwing: RecordingError.writeFailed) }
        do { try await session.start(recorder); XCTFail("실패 전달 필요") } catch {}
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(recorder.stopCount, 0)
    }

    @MainActor
    func testStopFailureIsNotReportedAsSuccess() async {
        let session = RecordingSession()
        let recorder = ControlledRecording()
        recorder.onStart = { recorder.startContinuation?.resume() }
        recorder.onStop = { recorder.stopContinuation?.resume(throwing: RecordingError.writeFailed) }
        do {
            try await session.start(recorder)
            _ = try await session.stop()
            XCTFail("저장 실패 전달 필요")
        } catch {}
        XCTAssertFalse(session.isBusy)
    }

    func testEmptyVideoCannotFinishSuccessfully() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = VideoFrameWriter(outputURL: url)
        try await frames.start(width: 128, height: 128)
        do { try await frames.finish(streamError: nil); XCTFail("빈 녹화는 실패해야 한다") } catch {}
    }

    func testRealFramesProduceReadableMP4() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("capture.mp4")
        defer { try? FileManager.default.removeItem(at: directory) }
        // 샘플 PTS와 같은 시계. 중지 시각은 마지막 프레임 직후.
        let clock = TestClock(seconds: 6.0 / 30)
        let frames = VideoFrameWriter(outputURL: url, clock: clock.read)
        try await frames.start(width: 128, height: 128)
        for frame in 0..<6 { try await Self.append(frames, at: Double(frame) / 30) }
        try await frames.finish(streamError: nil)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)

        let range = CMTimeRange(start: .zero, duration: duration)
        async let firstGIF = VideoExportService.exportGIF(source: url, timeRange: range, frameCount: 3)
        async let secondGIF = VideoExportService.exportGIF(source: url, timeRange: range, frameCount: 3)
        async let trimmed = VideoExportService.exportMP4(source: url, timeRange: range)
        let (first, second, mp4) = try await (firstGIF, secondGIF, trimmed)
        XCTAssertNotEqual(first, second, "동시 내보내기가 서로의 파일을 덮어쓰면 안 된다")
        for gif in [first, second] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 3)
        }
        let exportedTracks = try await AVURLAsset(url: mp4).loadTracks(withMediaType: .video)
        XCTAssertEqual(exportedTracks.count, 1)
        do {
            _ = try await VideoExportService.exportGIF(source: url, timeRange: .zero, frameCount: 3)
            XCTFail("빈 구간 내보내기는 거부해야 한다")
        } catch {}
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains { $0.hasPrefix(".export-") }, "실패/완료 후 임시 파일이 남으면 안 된다")
    }

    func testCancelledWriterCannotFinishSuccessfully() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.cancelWriting()
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            VideoWriterFinalizer.finish(writer: writer, input: input, hasFrames: true) {
                continuation.resume(returning: $0)
            }
        }
        if case .success = result { XCTFail("취소된 writer는 성공이 아니다") }
    }

    @MainActor
    func testStopDuringFailedStartDoesNotReportSecondError() async throws {
        let session = RecordingSession()
        let recorder = ControlledRecording()
        let started = expectation(description: "녹화 시작 대기")
        recorder.onStart = { started.fulfill() }
        let start = Task { try await session.start(recorder) }
        await fulfillment(of: [started], timeout: 2)
        let stop = Task { try await session.stop() }
        while session.state != .stopping { await Task.yield() }
        recorder.startContinuation?.resume(throwing: RecordingError.writeFailed)
        do { try await start.value; XCTFail("시작 실패는 start 호출자에게 전달") } catch {}
        let url = try await stop.value
        XCTAssertNil(url, "시작 실패를 중지에서 다시 던지면 오류 창이 두 번 뜬다")
        XCTAssertEqual(recorder.stopCount, 0)
        XCTAssertFalse(session.isBusy)
    }

    func testTrailingStillPeriodIsKeptUntilStop() async throws {
        let url = Self.temporaryMP4URL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = TestClock(seconds: 0)
        let frames = VideoFrameWriter(outputURL: url, clock: clock.read)
        try await frames.start(width: 128, height: 128)
        for frame in 0..<6 { try await Self.append(frames, at: Double(frame) / 30) }
        // 이후 화면이 멈춰 완성 프레임이 오지 않다가 3초에 중지.
        clock.seconds = 3
        try await frames.finish(streamError: nil)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.05, "마지막 프레임 이후 정지 구간이 잘리면 안 된다")
    }

    func testPauseIsMeasuredFromSetPausedTimeOnStillScreen() async throws {
        let url = Self.temporaryMP4URL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = TestClock(seconds: 0)
        let frames = VideoFrameWriter(outputURL: url, clock: clock.read)
        try await frames.start(width: 128, height: 128)
        for frame in 0..<6 { try await Self.append(frames, at: Double(frame) / 30) }
        // 정지 화면: 일시정지 동안 프레임이 전혀 오지 않는다.
        clock.seconds = 1
        frames.setPaused(true)
        clock.seconds = 4
        frames.setPaused(false)
        for frame in 0..<6 { try await Self.append(frames, at: 4 + Double(frame) / 30) }
        clock.seconds = 5
        try await frames.finish(streamError: nil)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.05, "일시정지한 3초는 영상에서 빠져야 한다")
    }

    func testStopWhilePausedEndsAtPauseStart() async throws {
        let url = Self.temporaryMP4URL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = TestClock(seconds: 0)
        let frames = VideoFrameWriter(outputURL: url, clock: clock.read)
        try await frames.start(width: 128, height: 128)
        for frame in 0..<6 { try await Self.append(frames, at: Double(frame) / 30) }
        clock.seconds = 1
        frames.setPaused(true)
        clock.seconds = 3
        try await frames.finish(streamError: nil)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.05)
    }

    func testSessionEndTimeNeverPrecedesLastFrame() {
        func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        XCTAssertEqual(VideoFrameWriter.sessionEndTime(stopTime: t(10), pauseBeganAt: nil,
                                                       pausedDuration: t(2), lastFrameEnd: t(5)).seconds, 8, accuracy: 0.001)
        XCTAssertEqual(VideoFrameWriter.sessionEndTime(stopTime: t(10), pauseBeganAt: t(7),
                                                       pausedDuration: t(2), lastFrameEnd: t(4)).seconds, 5, accuracy: 0.001)
        XCTAssertEqual(VideoFrameWriter.sessionEndTime(stopTime: t(5), pauseBeganAt: nil,
                                                       pausedDuration: .zero, lastFrameEnd: t(5.5)).seconds, 5.5, accuracy: 0.001)
    }

    func testStreamErrorWithCompletedFileIsSuccess() async throws {
        let url = Self.temporaryMP4URL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = TestClock(seconds: 1)
        let frames = VideoFrameWriter(outputURL: url, clock: clock.read)
        try await frames.start(width: 128, height: 128)
        for frame in 0..<6 { try await Self.append(frames, at: Double(frame) / 30) }
        // 메뉴 막대의 "공유 중단"처럼 시스템이 스트림을 멈춘 경우.
        frames.markStopRequested()
        let streamError = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3817)
        try await frames.finish(streamError: streamError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    func testFailedWriterRemovesPartialFile() async throws {
        let url = Self.temporaryMP4URL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128
        ])
        writer.add(input)
        // 쓰는 도중 실패해 남은 조각 파일 흉내.
        try Data(repeating: 0, count: 64).write(to: url)
        XCTAssertFalse(writer.startWriting())
        XCTAssertEqual(writer.status, .failed)
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            VideoWriterFinalizer.finish(writer: writer, input: input, hasFrames: true) {
                continuation.resume(returning: $0)
            }
        }
        if case .success = result { XCTFail("실패한 writer는 성공이 아니다") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "깨진 파일이 보관함에 남으면 안 된다")
    }

    func testCancelledRecordingRemovesPartialFile() async throws {
        let url = Self.temporaryMP4URL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        XCTAssertTrue(input.append(try Self.makeSample(at: 0)))
        writer.cancelWriting()
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            VideoWriterFinalizer.finish(writer: writer, input: input, hasFrames: true) {
                continuation.resume(returning: $0)
            }
        }
        if case .success = result { XCTFail("취소된 writer는 성공이 아니다") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLargeAreaUsesHEVCAndStaysWithinEncoderLimits() {
        let fullHD = VideoOutputFormat(pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertEqual([fullHD.width, fullHD.height], [1920, 1080])
        XCTAssertEqual(fullHD.codec, .h264)
        XCTAssertEqual(VideoOutputFormat(pixelWidth: 4096, pixelHeight: 2304).codec, .h264)
        XCTAssertEqual(VideoOutputFormat(pixelWidth: 2304, pixelHeight: 4096).codec, .h264)
        let odd = VideoOutputFormat(pixelWidth: 301.4, pixelHeight: 1)
        XCTAssertEqual([odd.width, odd.height], [300, 2])
        // 5K 전체 화면, 6K 전체 화면, 세로 5K, 가로만 긴 영역.
        for (w, h) in [(5120, 2880), (6016, 3384), (2880, 5120), (4098, 1000)] {
            let format = VideoOutputFormat(pixelWidth: CGFloat(w), pixelHeight: CGFloat(h))
            XCTAssertEqual(format.codec, .hevc, "\(w)x\(h)")
            XCTAssertEqual([format.width, format.height], [w, h])
        }
        let huge = VideoOutputFormat(pixelWidth: 10_001, pixelHeight: 5_000)
        XCTAssertEqual(huge.codec, .hevc)
        XCTAssertLessThanOrEqual(huge.width, 8192)
        XCTAssertLessThanOrEqual(huge.height, 4320)
        XCTAssertEqual(huge.width % 2, 0)
        XCTAssertEqual(huge.height % 2, 0)
        XCTAssertEqual(Double(huge.width) / Double(huge.height), 2, accuracy: 0.01)
    }

    func test5KAreaRecordsWithSelectedCodec() async throws {
        let url = Self.temporaryMP4URL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = VideoOutputFormat(pixelWidth: 5120, pixelHeight: 2880)
        let clock = TestClock(seconds: 0.5)
        let frames = VideoFrameWriter(outputURL: url, clock: clock.read)
        try await frames.start(width: format.width, height: format.height, codec: format.codec)
        for frame in 0..<3 {
            try await Self.append(frames, at: Double(frame) / 30, width: format.width, height: format.height)
        }
        try await frames.finish(streamError: nil)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 5120, height: 2880))
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_HEVC)
    }

    private static func temporaryMP4URL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    }

    /// 녹화 큐에서 프레임을 넣고, 실제 녹화의 프레임 간격처럼 인코더가 입력을 소비하도록 기다린다.
    private static func append(_ frames: VideoFrameWriter, at seconds: Double,
                               width: Int = 128, height: Int = 128) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            frames.queue.async {
                do { frames.append(try makeSample(at: seconds, width: width, height: height)); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
        try await Task.sleep(nanoseconds: 35_000_000)
    }

    private static func makeSample(at seconds: Double, width: Int = 128, height: Int = 128) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), 128, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                     formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
                                                sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
}
