import AppKit
import ScreenCaptureKit

extension Notification.Name {
    static let videoRecordingStateDidChange = Notification.Name("com.goldenrabbit.ohmyopensnap.videoRecordingStateDidChange")
}

@MainActor
final class VideoRecordingController {
    static let shared = VideoRecordingController()
    private init() {}

    private var recorder: AreaVideoRecorder?
    private var hud: RecordingHUD?
    private(set) var isPaused = false

    var isRecording: Bool { recorder != nil }

    func start(display: SCDisplay,
               displayID: CGDirectDisplayID,
               rect: CGRect,
               scale: CGFloat,
               excluding: [SCWindow]) async throws {
        guard recorder == nil else { return }

        let outputURL = Self.uniqueMP4URL(for: Date())
        let recorder = AreaVideoRecorder(display: display,
                                         sourceRect: rect.integral,
                                         outputURL: outputURL,
                                         scale: scale,
                                         excluding: excluding)
        try await recorder.start()
        self.recorder = recorder
        isPaused = false
        let hud = RecordingHUD(onPauseToggle: { [weak self] in
            self?.togglePause()
        }, onStop: { [weak self] in
            self?.stop()
        })
        self.hud = hud
        hud.show()
        LibraryWindowController.shared.restoreAfterCapture()
        NotificationCenter.default.post(name: .videoRecordingStateDidChange, object: nil)
        if Settings.shared.playSound {
            NSSound(named: NSSound.Name("Pop"))?.play()
        }
    }

    func togglePause() {
        guard let recorder else { return }
        isPaused.toggle()
        recorder.setPaused(isPaused)
        hud?.setPaused(isPaused)
        NotificationCenter.default.post(name: .videoRecordingStateDidChange, object: nil)
    }

    func stop() {
        guard let recorder else { return }
        self.recorder = nil
        isPaused = false
        hud?.dismiss()
        hud = nil
        NotificationCenter.default.post(name: .videoRecordingStateDidChange, object: nil)

        Task {
            let url = await recorder.stop()
            await MainActor.run {
                Self.copyFileURLToClipboard(url)
                CaptureLibrary.shared.fileDidChange(url)
                LibraryWindowController.shared.showWindowSelectingLatest()
                if Settings.shared.playSound {
                    NSSound(named: NSSound.Name("Pop"))?.play()
                }
            }
        }
    }

    private static func uniqueMP4URL(for date: Date) -> URL {
        try? FileManager.default.createDirectory(at: Settings.shared.libraryDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"

        let base = formatter.string(from: date)
        var url = Settings.shared.libraryDirectory.appendingPathComponent(base + ".mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Settings.shared.libraryDirectory.appendingPathComponent("\(base)-\(suffix).mp4")
            suffix += 1
        }
        return url
    }

    private static func copyFileURLToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }
}
