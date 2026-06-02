import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// 라이브 확대경(루페)용 프레임 공급자.
/// 디스플레이 전체를 낮은 지연으로 스트리밍하며 최신 프레임 1장만 캐시한다.
/// 오버레이 윈도우는 `sharingType = .none`이라 캡처에 찍히지 않는다(자기참조 차단).
final class DisplayStreamProvider: NSObject, SCStreamOutput {
    let displayID: CGDirectDisplayID
    let scale: CGFloat

    private var stream: SCStream?
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private let sampleQueue: DispatchQueue

    init(displayID: CGDirectDisplayID, scale: CGFloat) {
        self.displayID = displayID
        self.scale = scale
        self.sampleQueue = DispatchQueue(label: "com.goldenrabbit.appresizer.loupe.\(displayID)")
        super.init()
    }

    func start(display: SCDisplay) async {
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            NSLog("DisplayStreamProvider start failed for \(displayID): \(error)")
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil
        lock.lock(); latest = nil; lock.unlock()
    }

    func latestBuffer() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = pixelBuffer
        lock.unlock()
    }
}
