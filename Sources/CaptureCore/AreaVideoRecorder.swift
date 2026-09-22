import AVFoundation
import ScreenCaptureKit

@MainActor
final class AreaVideoRecorder: NSObject, Recording, SCStreamOutput, SCStreamDelegate {
    private let display: SCDisplay
    private let sourceRect: CGRect
    private let outputURL: URL
    private let scale: CGFloat
    private let excluding: [SCWindow]
    nonisolated private let frames: VideoFrameWriter
    private var stream: SCStream?
    private var streamError: Error?
    var onFailure: ((Error) -> Void)?

    init(display: SCDisplay, sourceRect: CGRect, outputURL: URL, scale: CGFloat, excluding: [SCWindow]) {
        self.display = display
        self.sourceRect = sourceRect
        self.outputURL = outputURL
        self.scale = scale
        self.excluding = excluding
        frames = VideoFrameWriter(outputURL: outputURL)
        super.init()
    }

    func start() async throws {
        // 짝수 크기, 코덱 한계를 넘는 영역은 HEVC(필요하면 축소). 스트림도 같은 크기로 받는다.
        let format = VideoOutputFormat(pixelWidth: sourceRect.width * scale, pixelHeight: sourceRect.height * scale)
        try await frames.start(width: format.width, height: format.height, codec: format.codec)
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = format.width
        config.height = format.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8
        config.showsCursor = true
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: excluding),
                              configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames.queue)
            self.stream = stream
            try await stream.startCapture()
        } catch {
            self.stream = nil
            await frames.cancel()
            throw error
        }
    }

    func stop() async throws -> URL {
        // 영상은 누른 시각까지 이어진다. 스트림 정지를 기다리는 동안 찍힌 프레임은 넣지 않는다.
        frames.markStopRequested()
        if let stream {
            self.stream = nil
            do { try await stream.stopCapture() }
            catch { if streamError == nil { streamError = error } }
        }
        try await frames.finish(streamError: streamError)
        return outputURL
    }

    func setPaused(_ paused: Bool) { frames.setPaused(paused) }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        if type == .screen { frames.append(sampleBuffer) }
    }

    /// 공유 중단·디스플레이 분리 등 시스템이 멈춘 경우. 그때까지 녹화된 파일은 정상 저장한다.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        frames.markStopRequested()
        Task { @MainActor in
            guard self.stream != nil else { return }
            self.streamError = error
            self.onFailure?(error)
        }
    }
}
