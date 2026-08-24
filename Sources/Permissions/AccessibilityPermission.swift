import AppKit
import ApplicationServices

/// 다른 앱이 공개한 접근성 트리로 창의 툴바와 콘텐츠 시작점을 읽기 위한 권한.
/// 화면 픽셀이나 키 입력을 읽는 권한과는 별개다.
enum AccessibilityPermission {
    /// 이미 접근성 권한을 받았는지 확인한다. 시스템 안내는 띄우지 않는다.
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// macOS의 접근성 권한 안내를 요청한다.
    @discardableResult
    static func request() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 시스템 설정의 손쉬운 사용 > 접근성 패널을 연다.
    static func openSystemSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
