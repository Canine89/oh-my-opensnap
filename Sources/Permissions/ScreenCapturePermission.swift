import AppKit
import CoreGraphics

/// 화면 녹화 권한(TCC)은 entitlement가 아니라 사용자 동의로만 부여된다.
/// 코드로는 프리플라이트 확인과 시스템 prompt 유도, 설정 딥링크만 가능하다.
enum ScreenCapturePermission {
    /// 이미 허용되었는지 확인 (prompt 없음).
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 시스템 권한 prompt를 띄운다. 최초 호출 시 사용자가 결정하기 전이면 false를 반환할 수 있다.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 시스템 설정의 "화면 및 시스템 오디오 녹화" 패널을 연다.
    static func openSystemSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
enum PermissionAlert {
    @discardableResult
    static func show() -> Bool {
        let alert = NSAlert()
        alert.messageText = loc("Screen Recording permission is required", "화면 녹화 권한이 필요합니다")
        alert.informativeText = loc("""
        \(Brand.name) needs your permission in System Settings before it can capture the screen.

        Turn on \(Brand.name) in the 'Screen & System Audio Recording' list, then return to the app. If macOS requests a relaunch, quit and open the app again.
        If it is already on, turn it off and on again so macOS picks up the new permission.
        """, """
        \(Brand.name)이 화면을 캡처하려면 시스템 설정에서 권한을 허용해야 합니다.

        '화면 및 시스템 오디오 녹화' 목록에서 \(Brand.name)을 켠 뒤 앱으로 돌아오세요. macOS가 재실행을 요청하면 앱을 종료하고 다시 열어 주세요.
        이미 켜져 있다면 한 번 끄고 다시 켜야 macOS가 새 권한을 반영할 수 있습니다.
        """)
        alert.alertStyle = .informational
        alert.addButton(withTitle: loc("Open System Settings", "시스템 설정 열기"))
        alert.addButton(withTitle: loc("Cancel", "취소"))
        // accessory 앱은 활성화하지 않으면 알림창이 다른 앱 뒤에 묻힌다.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenCapturePermission.openSystemSettings()
            return true
        }
        return false
    }
}
