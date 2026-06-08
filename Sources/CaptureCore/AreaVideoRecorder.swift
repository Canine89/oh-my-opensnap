import AVFoundation
import ScreenCaptureKit

final class AreaVideoRecorder: NSObject, SCStreamOutput {
    private let display: SCDisplay
    private let sourceRect: CGRect
    private let outputURL: URL
    private let scale: CGFloat
    private let excluding: [SCWindow]
    private let sampleQueue = DispatchQueue(label: "com.goldenrabbit.ohmyopensnap.video-recorder")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var didStartSession = false
    private var isStopping = false

    init(display: SCDisplay, sourceRect: CGRect, outputURL: URL, scale: CGFloat, excluding: [SCWindow]) {
        self.display = display
        self.sourceRect = sourceRect
        self.outputURL = outputURL
        self.scale = scale
        self.excluding = excluding
        super.init()
    }

    func start() async throws {
        try? FileManager.default.removeItem(at: outputURL)

        let pixelWidth = max(2, Int((sourceRect.width * scale).rounded()))
        let pixelHeight = max(2, Int((sourceRect.height * scale).rounded()))

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight
        ])
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else { throw NSError(domain: "AreaVideoRecorder", code: 1) }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "AreaVideoRecorder", code: 2)
        }

        let filter = SCContentFilter(display: display, excludingWindows: excluding)
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        self.writer = writer
        self.input = input
        self.stream = stream
    }

    func stop() async -> URL {
        isStopping = true
        let stream = stream
        self.stream = nil

        if let stream {
            await withCheckedContinuation { continuation in
                stream.stopCapture { _ in continuation.resume() }
            }
        }

        let finisher: AssetWriterFinisher?
        if let writer, let input {
            finisher = AssetWriterFinisher(writer: writer, input: input)
        } else {
            finisher = nil
        }
        self.writer = nil
        self.input = nil

        await withCheckedContinuation { continuation in
            sampleQueue.async {
                guard let finisher else {
                    continuation.resume()
                    return
                }
                finisher.finish {
                    continuation.resume()
                }
            }
        }

        return outputURL
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              !isStopping,
              sampleBuffer.isValid,
              isCompleteFrame(sampleBuffer),
              let writer,
              let input,
              input.isReadyForMoreMediaData else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !didStartSession {
            writer.startSession(atSourceTime: presentationTime)
            didStartSession = true
        }
        input.append(sampleBuffer)
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }
        return status == .complete
    }
}

private final class AssetWriterFinisher: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
    }

    func finish(completion: @escaping () -> Void) {
        input.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }
}
