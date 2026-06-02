import ScreenCaptureKit
import CoreGraphics

/// 커서 아래의 캡처 가능한 윈도우를 찾는다.
/// 좌표는 CG 전역 공간(좌상단 원점, point) 기준이며 `SCWindow.frame`과 동일하다.
struct WindowCandidate {
    let scWindow: SCWindow
    let cgFrame: CGRect          // 전역, 좌상단 원점, point
}

final class WindowHitTester {
    /// 실제 화면 z-order(front-to-back)로 정렬된 후보. 첫 매치 = 최상단 윈도우.
    let candidates: [WindowCandidate]

    init(content: SCShareableContent) {
        let myBundleID = Bundle.main.bundleIdentifier

        // SCWindow를 windowID로 매핑 (sharingType=.none인 우리 오버레이는 애초에 포함되지 않음)
        var byID: [CGWindowID: SCWindow] = [:]
        for window in content.windows { byID[window.windowID] = window }

        // CGWindowList는 front-to-back z-order를 보장한다. 이 순서가 핵심.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        var ordered: [WindowCandidate] = []
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,   // 일반 윈도우만
                  let windowNumber = info[kCGWindowNumber as String] as? Int
            else { continue }

            guard let scWindow = byID[CGWindowID(windowNumber)],
                  scWindow.owningApplication?.bundleIdentifier != myBundleID,        // 우리 앱 제외
                  scWindow.frame.width >= 40, scWindow.frame.height >= 40
            else { continue }

            ordered.append(WindowCandidate(scWindow: scWindow, cgFrame: scWindow.frame))
        }
        candidates = ordered
    }

    /// 전역 CG 좌표 아래의 최상단(frontmost) 윈도우만 반환. 뒤에 가려진 창은 무시.
    func window(at globalPoint: CGPoint) -> WindowCandidate? {
        candidates.first { $0.cgFrame.contains(globalPoint) }
    }
}
