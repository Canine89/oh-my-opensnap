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

    /// AppKit 전역 원점이 있는 메인 화면 높이(point). AX 좌표를 CG 좌표로 뒤집을 때 쓴다.
    static var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
    }

    /// AX/AppKit 전역 좌표(좌하단 원점, y 위) → CG 전역 좌표(좌상단 원점, y 아래).
    static func cgRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryHeight - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    static func frameDelta(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}
