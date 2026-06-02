import AppKit

/// 캡처 진입 흐름을 한 곳에서 관리한다: 권한 확인 → 오버레이 시작.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    private init() {}

    func startAreaCapture() {
        guard ensurePermission() else { return }
        OverlayController.shared.begin()
    }

    private func ensurePermission() -> Bool {
        if ScreenCapturePermission.isGranted { return true }

        // 최초 진입이면 시스템 prompt를 띄운다.
        ScreenCapturePermission.request()

        if ScreenCapturePermission.isGranted { return true }

        // 아직 허용되지 않았으면 설정으로 안내. 권한 부여 후 재실행이 필요할 수 있다.
        PermissionAlert.show()
        return false
    }
}
