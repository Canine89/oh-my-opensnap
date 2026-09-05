import AppKit
import ScreenCaptureKit

extension Notification.Name {
    static let videoRecordingStateDidChange = Notification.Name("com.goldenrabbit.ohmyopensnap.videoRecordingStateDidChange")
}

@MainActor
final class VideoRecordingController {
    static let shared = VideoRecordingController()
    private init() {}

    private let session = RecordingSession()
    private var finishTask: Task<URL?, Error>?
    private var isShuttingDown = false
    private var hud: RecordingHUD?
    private var regionOverlay: RecordingRegionOverlay?
    private(set) var isPaused = false

    var isRecording: Bool { session.isBusy || finishTask != nil }

    func start(display: SCDisplay,
               displayID: CGDirectDisplayID,
               rect: CGRect,
               scale: CGFloat,
               excluding: [SCWindow]) async throws {
        guard !isShuttingDown, !isRecording else { throw RecordingError.busy }

        let outputURL = Self.uniqueMP4URL(for: Date())
        let recorder = AreaVideoRecorder(display: display,
                                         sourceRect: rect.integral,
                                         outputURL: outputURL,
                                         scale: scale,
                                         excluding: excluding)
        recorder.onFailure = { [weak self] _ in self?.stop() }
        defer { NotificationCenter.default.post(name: .videoRecordingStateDidChange, object: nil) }
        try await session.start(recorder)
        guard session.isCurrent(recorder), session.state == .recording, !isShuttingDown else { return }
        isPaused = false
        let regionOverlay = RecordingRegionOverlay(displayID: displayID, captureRect: rect.integral)
        self.regionOverlay = regionOverlay
        let hud = RecordingHUD(onPauseToggle: { [weak self] in
            self?.togglePause()
        }, onStop: { [weak self] in
            self?.stop()
        })
        self.hud = hud
        regionOverlay?.show()
        hud.show()
        LibraryWindowController.shared.restoreAfterCapture()
        NotificationCenter.default.post(name: .videoRecordingStateDidChange, object: nil)
        if Settings.shared.playSound {
            NSSound(named: NSSound.Name("Pop"))?.play()
        }
    }

    func togglePause() {
        guard session.state == .recording else { return }
        isPaused.toggle()
        session.setPaused(isPaused)
        hud?.setPaused(isPaused)
        NotificationCenter.default.post(name: .videoRecordingStateDidChange, object: nil)
    }

    func stop() {
        guard isRecording, finishTask == nil else { return }
        let task = beginFinishing()
        Task {
            do {
                if let url = try await task.value, !isShuttingDown {
                    Self.copyFileURLToClipboard(url)
                    CaptureLibrary.shared.fileDidChange(url)
                    LibraryWindowController.shared.showWindow(selecting: url)
                    if Settings.shared.playSound { NSSound(named: NSSound.Name("Pop"))?.play() }
                }
            } catch {
                if !isShuttingDown {
                    OperationErrorPresenter.show(error, action: loc("Could not save the recording", "녹화 파일을 저장하지 못했습니다"))
                }
            }
        }
    }

    /// 이미 중지 버튼을 누른 경우에도 같은 저장 작업이 끝날 때까지 기다린다.
    func finishForTermination() async throws {
        isShuttingDown = true
        defer { isShuttingDown = false }
        _ = try await (finishTask ?? beginFinishing()).value
    }

    private func beginFinishing() -> Task<URL?, Error> {
        isPaused = false
        hud?.dismiss()
        hud = nil
        regionOverlay?.dismiss()
        regionOverlay = nil
        let task = Task { () throws -> URL? in
            defer {
                finishTask = nil
                NotificationCenter.default.post(name: .videoRecordingStateDidChange, object: nil)
            }
            return try await session.stop()
        }
        finishTask = task
        NotificationCenter.default.post(name: .videoRecordingStateDidChange, object: nil)
        return task
    }

    private static func uniqueMP4URL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        // 시작 전 파일 탐색/생성을 메인에서 하지 않는다. 실제 생성은 프레임 I/O 큐에서.
        return Settings.shared.libraryDirectory.appendingPathComponent(
            formatter.string(from: date) + "-" + UUID().uuidString + ".mp4")
    }

    private static func copyFileURLToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }
}
