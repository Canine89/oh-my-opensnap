import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// 라이브 확대경(루페)용 프레임 공급자.
/// 루페는 커서 주변 수십 픽셀만 쓰므로 풀 Retina·60fps 대신 축소·저fps로 스트림한다.
/// 오버레이 윈도우는 `start(display:excluding:)`의 제외 목록으로 캡처에서 빠진다(자기참조 차단).
final class DisplayStreamProvider: NSObject, SCStreamOutput {
    let displayID: CGDirectDisplayID
    /// 화면 point → 스트림 버퍼 픽셀 스케일. 루페 샘플링 좌표에 쓴다.
    private(set) var bufferScale: CGFloat
    private let targetScale: CGFloat

    private var stream: SCStream?
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private let sampleQueue: DispatchQueue
    private(set) var isRunning = false
    /// start() await 중 stop()이 오면 완료 후 바로 폐기하기 위한 세대 카운터.
    private var startGeneration = 0

    /// - Parameters:
    ///   - displayID: 대상 디스플레이
    ///   - scale: 화면 backingScaleFactor (예: 2.0)
    ///   - quality: 루페용 축소 비율(기본 0.5 → Retina에서도 대략 1x 분량)
    init(displayID: CGDirectDisplayID, scale: CGFloat, quality: CGFloat = 0.5) {
        self.displayID = displayID
        self.targetScale = max(0.25, min(scale, scale * quality))
        self.bufferScale = self.targetScale
        self.sampleQueue = DispatchQueue(label: "com.goldenrabbit.ohmyopensnap.loupe.\(displayID)")
        super.init()
    }

    func start(display: SCDisplay, excluding: [SCWindow] = []) async {
        guard !isRunning else { return }
        startGeneration += 1
        let generation = startGeneration

        let filter = SCContentFilter(display: display, excludingWindows: excluding)

        let config = SCStreamConfiguration()
        config.width = max(2, Int((CGFloat(display.width) * targetScale).rounded()))
        config.height = max(2, Int((CGFloat(display.height) * targetScale).rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 20)   // 20fps면 루페에 충분
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = false
        bufferScale = targetScale

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            guard generation == startGeneration else {
                stream.stopCapture(completionHandler: { _ in })
                return
            }
            self.stream = stream
            isRunning = true
        } catch {
            NSLog("DisplayStreamProvider start failed for \(displayID): \(error)")
            isRunning = false
        }
    }

    func stop() {
        startGeneration += 1
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil
        isRunning = false
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
