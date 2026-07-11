import AppKit

/// 캡처 진입 흐름을 한 곳에서 관리한다: 권한 확인 → 오버레이 시작.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    private var didRequestPermissionThisLaunch = false
    private init() {}

    func startAreaCapture() {
        guard ensurePermission() else { return }
        OverlayController.shared.begin(mode: .askAfterSelection)
    }

    func startAreaVideoRecording() {
        guard ensurePermission() else { return }
        OverlayController.shared.begin(mode: .video)
    }

    private func ensurePermission() -> Bool {
        if ScreenCapturePermission.isGranted { return true }

        // 시스템 prompt와 자체 안내창을 한 번의 캡처 시도에서 연달아 띄우지 않는다.
        // 최초 요청에서는 macOS 표준 prompt만 맡기고, 같은 실행 중 다시 시도할 때만
        // 설정 안내를 보여 준다. 권한을 켠 뒤 재실행하면 preflight에서 바로 통과한다.
        if !didRequestPermissionThisLaunch {
            didRequestPermissionThisLaunch = true
            if ScreenCapturePermission.request() || ScreenCapturePermission.isGranted {
                return true
            }
            return false
        }

        // 이미 표준 요청을 했는데도 허용되지 않은 경우에만 설정으로 안내한다.
        PermissionAlert.show()
        return false
    }
}
