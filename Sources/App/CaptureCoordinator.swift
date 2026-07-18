import AppKit

/// 캡처 진입 흐름을 한 곳에서 관리한다: 권한 확인 → 오버레이 시작.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var didRequestPermissionThisLaunch = false
    private var pendingStart: (() -> Void)?
    private var pollTimer: Timer?
    private var pollAttempts = 0
    private let maxPollAttempts = 75   // 0.4s × 75 ≈ 30초

    private init() {}

    func startAreaCapture() {
        attemptStart { OverlayController.shared.begin(mode: .askAfterSelection) }
    }

    func startAreaVideoRecording() {
        attemptStart { OverlayController.shared.begin(mode: .video) }
    }

    private func attemptStart(_ action: @escaping () -> Void) {
        if ScreenCapturePermission.isGranted {
            stopPolling()
            pendingStart = nil
            action()
            return
        }

        pendingStart = action

        // 시스템 prompt와 자체 안내창을 한 번의 캡처 시도에서 연달아 띄우지 않는다.
        // 최초 요청에서는 macOS 표준 prompt만 맡기고, 허용될 때까지 짧게 폴링한다.
        if !didRequestPermissionThisLaunch {
            didRequestPermissionThisLaunch = true
            if ScreenCapturePermission.request() || ScreenCapturePermission.isGranted {
                stopPolling()
                pendingStart = nil
                action()
                return
            }
            startPolling()
            return
        }

        // 이미 표준 요청을 했고 폴링 중이면 추가 안내창을 띄우지 않는다.
        if pollTimer != nil { return }

        // 폴링이 끝났는데도 허용되지 않은 경우에만 설정으로 안내한다.
        PermissionAlert.show()
    }

    private func startPolling() {
        stopPolling()
        pollAttempts = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPermission()
            }
        }
    }

    private func pollPermission() {
        if ScreenCapturePermission.isGranted {
            let action = pendingStart
            stopPolling()
            pendingStart = nil
            action?()
            return
        }

        pollAttempts += 1
        if pollAttempts >= maxPollAttempts {
            stopPolling()
            // 사용자가 시스템 창을 닫았거나 거부한 경우 — 다음 단축키에서 안내창을 보여 준다.
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollAttempts = 0
    }
}
