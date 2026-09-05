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
        let frames = VideoFrameWriter(outputURL: url)
        try await frames.start(width: 128, height: 128)
        for frame in 0..<6 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                frames.queue.async {
                    do { frames.append(try Self.makeSample(frame: frame)); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
            // 인코더가 입력을 소비하도록 한다. 실제 녹화의 프레임 간격과 같은 조건.
            try await Task.sleep(nanoseconds: 35_000_000)
        }
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

    private static func makeSample(frame: Int) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA,
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
                                        presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
                                                sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
}
