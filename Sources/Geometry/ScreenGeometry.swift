import AppKit

/// 화면 좌표계 변환 헬퍼.
/// - AppKit: 전역 원점이 메인 화면 좌하단, y 위로 증가.
/// - 픽셀/캡처: 디스플레이 원점이 좌상단, y 아래로 증가.
/// 오버레이 뷰는 `isFlipped == true`로 좌상단 기준 point 좌표를 사용한다.
enum ScreenGeometry {
    /// `CGDirectDisplayID`에 해당하는 NSScreen.
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}
