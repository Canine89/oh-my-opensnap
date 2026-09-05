import AVFoundation
import ScreenCaptureKit

@MainActor
final class AreaVideoRecorder: NSObject, Recording, SCStreamOutput, SCStreamDelegate {
    private let display: SCDisplay
    private let sourceRect: CGRect
    private let outputURL: URL
    private let scale: CGFloat
    private let excluding: [SCWindow]
    private let libraryAccess: SecurityScopedAccess?
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
        libraryAccess = Settings.shared.retainLibraryAccess(for: outputURL)
        frames = VideoFrameWriter(outputURL: outputURL)
        super.init()
    }

    func start() async throws {
        // H.264가 요구하는 짝수 크기로 맞춘다.
        let width = max(2, Int((sourceRect.width * scale).rounded()) / 2 * 2)
        let height = max(2, Int((sourceRect.height * scale).rounded()) / 2 * 2)
        try await frames.start(width: width, height: height)
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = width
        config.height = height
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

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream != nil else { return }
            self.streamError = error
            self.onFailure?(error)
        }
    }
}
