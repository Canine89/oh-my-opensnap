import AppKit
import ApplicationServices

/// 다른 앱 창의 상단 헤더(타이틀바·툴바·탭바) 높이를 잰다.
///
/// 콘텐츠(웹뷰/스크롤)를 추정하면 Electron·브라우저·스플릿 뷰에서 사이드바나
/// 안쪽 패널을 집는다. 헤더 밴드를 직접 찾고, 본문은 `창 − 헤더`로 둔다.
enum WindowChromeDetector {
    /// CG 전역 좌표 창 프레임에서 잘라낼 상단 헤더 높이(point).
    static func topInset(pid: pid_t,
                         windowFrame: CGRect,
                         cursor: CGPoint,
                         primaryHeight: CGFloat) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        guard let match = matchingWindow(in: app, fullRect: windowFrame, primaryHeight: primaryHeight) else {
            return nil
        }

        // 본문(큰 스크롤/웹 영역)이 시작되는 위치가 가장 믿을 만하다.
        // 신호등만 보면 카톡처럼 타이틀바 아래 앱 헤더를 관통한다.
        let contentStart = primaryContentTopInset(in: match.element, fullRect: windowFrame, align: match.align)
        let chrome = chromeBandHeight(in: match.element, fullRect: windowFrame, align: match.align)
        var inset = contentStart ?? chrome

        if let hit = hitChromeHeight(app: app,
                                     window: match.element,
                                     cursor: cursor,
                                     fullRect: windowFrame,
                                     primaryHeight: primaryHeight,
                                     align: match.align) {
            inset = max(inset ?? 0, hit)
        }

        guard let inset, inset >= 20, inset <= min(220, windowFrame.height * 0.45) else { return nil }
        return inset
    }

    // MARK: - Window match

    private static func matchingWindow(in app: AXUIElement,
                                       fullRect: CGRect,
                                       primaryHeight: CGFloat) -> (element: AXUIElement, align: (CGRect) -> CGRect)? {
        guard let windows = elements(app, attribute: kAXWindowsAttribute) else { return nil }
        let matched = windows.compactMap { element -> (AXUIElement, CGFloat, (CGRect) -> CGRect)? in
            guard let raw = rect(element) else { return nil }
            let align = aligner(windowRaw: raw, fullRect: fullRect, primaryHeight: primaryHeight)
            return (element, ScreenGeometry.frameDelta(align(raw), fullRect), align)
        }
        .filter { $0.1 < 160 }
        .min { $0.1 < $1.1 }

        // focused/main fallback은 뒤에 가려진 창을 호버할 때 엉뚱한 창을 집는다.
        guard let matched else { return nil }
        return (matched.0, matched.2)
    }

    private static func aligner(windowRaw: CGRect,
                                fullRect: CGRect,
                                primaryHeight: CGFloat) -> (CGRect) -> CGRect {
        let flipped = ScreenGeometry.cgRect(fromAX: windowRaw, primaryHeight: primaryHeight)
        if ScreenGeometry.frameDelta(flipped, fullRect) + 4 < ScreenGeometry.frameDelta(windowRaw, fullRect) {
            return { ScreenGeometry.cgRect(fromAX: $0, primaryHeight: primaryHeight) }
        }
        return { $0 }
    }

    /// 창을 거의 가로지르는 큰 스크롤/웹 영역의 상단 = 앱 헤더가 끝나는 지점.
    private static func primaryContentTopInset(in window: AXUIElement,
                                               fullRect: CGRect,
                                               align: (CGRect) -> CGRect) -> CGFloat? {
        var best: CGFloat?
        func consider(_ frame: CGRect) {
            guard !frame.isNull else { return }
            let widthRatio = frame.width / max(fullRect.width, 1)
            let heightRatio = frame.height / max(fullRect.height, 1)
            let top = frame.minY - fullRect.minY
            guard widthRatio >= 0.82, heightRatio >= 0.28, top >= 20, top <= 180 else { return }
            if best == nil || top < best! { best = top }
        }

        func walk(_ root: AXUIElement, depth: Int) {
            guard depth <= 2 else { return }
            for child in children(of: root) {
                guard let raw = rect(child) else { continue }
                let frame = align(raw).intersection(fullRect)
                if isPrimaryContentRole(role(child)) {
                    consider(frame)
                }
                if isContainer(role(child)) {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(window, depth: 0)
        return best
    }

    private static func isPrimaryContentRole(_ role: String?) -> Bool {
        role == kAXScrollAreaRole || role == "AXWebArea" || role == kAXTextAreaRole || role == kAXSplitGroupRole
    }

    // MARK: - Chrome band from the window tree

    private static func chromeBandHeight(in window: AXUIElement,
                                         fullRect: CGRect,
                                         align: (CGRect) -> CGRect) -> CGFloat? {
        var bottoms: [CGFloat] = []
        collectChromeBottoms(in: window,
                             fullRect: fullRect,
                             align: align,
                             depth: 0,
                             maxDepth: 3,
                             bottoms: &bottoms)
        guard let maxBottom = bottoms.max() else { return nil }
        return maxBottom - fullRect.minY
    }

    private static func collectChromeBottoms(in root: AXUIElement,
                                             fullRect: CGRect,
                                             align: (CGRect) -> CGRect,
                                             depth: Int,
                                             maxDepth: Int,
                                             bottoms: inout [CGFloat]) {
        guard depth <= maxDepth else { return }
        for child in children(of: root) {
            guard let raw = rect(child) else { continue }
            let frame = align(raw).intersection(fullRect)
            guard !frame.isNull, frame.height > 2, frame.width > 2 else { continue }

            let almostFullWindow = frame.height > fullRect.height * 0.55
                && frame.width > fullRect.width * 0.7
            if almostFullWindow {
                collectChromeBottoms(in: child,
                                     fullRect: fullRect,
                                     align: align,
                                     depth: depth + 1,
                                     maxDepth: maxDepth,
                                     bottoms: &bottoms)
                continue
            }

            if isTopChrome(frame, fullRect: fullRect, element: child) {
                bottoms.append(frame.maxY)
            }

            if depth < 2, isContainer(role(child)) {
                collectChromeBottoms(in: child,
                                     fullRect: fullRect,
                                     align: align,
                                     depth: depth + 1,
                                     maxDepth: maxDepth,
                                     bottoms: &bottoms)
            }
        }
    }

    private static func isTopChrome(_ frame: CGRect, fullRect: CGRect, element: AXUIElement) -> Bool {
        let topAligned = frame.minY <= fullRect.minY + 12
        let shortEnough = frame.height <= 200
        let wideEnough = frame.width >= fullRect.width * 0.45
        let traffic = isTrafficLight(element)
        guard topAligned, shortEnough, (wideEnough || traffic) else { return false }
        if traffic { return true }
        if isChromeRole(role(element), subrole: subrole(element)) { return true }
        // Electron/커스텀 타이틀바는 역할 없이 상단 AXGroup인 경우가 많다.
        return role(element) == kAXGroupRole && wideEnough && frame.height >= 22 && frame.height <= 88
    }

    private static func isChromeRole(_ role: String?, subrole: String?) -> Bool {
        switch role {
        case kAXToolbarRole, kAXTabGroupRole, "AXTabGroup":
            return true
        case kAXGroupRole, kAXRadioGroupRole:
            return subrole == "AXTabGroup" || subrole == kAXTabGroupRole
        default:
            break
        }
        return isTrafficLight(role: role, subrole: subrole)
    }

    private static func isTrafficLight(_ element: AXUIElement) -> Bool {
        isTrafficLight(role: role(element), subrole: subrole(element))
    }

    private static func isTrafficLight(role: String?, subrole: String?) -> Bool {
        switch subrole {
        case kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole, kAXFullScreenButtonSubrole:
            return true
        default:
            return role == kAXButtonRole && (subrole?.contains("Close") == true
                || subrole?.contains("Minimize") == true
                || subrole?.contains("Zoom") == true)
        }
    }

    private static func isContainer(_ role: String?) -> Bool {
        role == kAXGroupRole || role == kAXSplitGroupRole
    }

    // MARK: - Cursor hit-test

    /// 커서 아래 요소가 툴바/탭/신호등이면 그 요소 하단까지를 헤더로 본다.
    private static func hitChromeHeight(app: AXUIElement,
                                        window: AXUIElement,
                                        cursor: CGPoint,
                                        fullRect: CGRect,
                                        primaryHeight: CGFloat,
                                        align: (CGRect) -> CGRect) -> CGFloat? {
        guard fullRect.insetBy(dx: -2, dy: -2).contains(cursor),
              let hit = element(at: cursor, in: app, primaryHeight: primaryHeight)
        else { return nil }

        var current: AXUIElement? = hit
        for _ in 0..<8 {
            guard let node = current else { break }
            if nodesEqual(node, window) { break }

            if isChromeRole(role(node), subrole: subrole(node)) || isTrafficLight(node),
               let raw = rect(node) {
                let frame = align(raw).intersection(fullRect)
                if !frame.isNull, frame.minY <= fullRect.minY + 16, frame.height <= 200 {
                    return frame.maxY - fullRect.minY
                }
            }
            current = child(node, attribute: kAXParentAttribute)
        }
        return nil
    }

    private static func element(at cgPoint: CGPoint,
                                in app: AXUIElement,
                                primaryHeight: CGFloat) -> AXUIElement? {
        if let hit = copyElement(in: app, x: cgPoint.x, y: cgPoint.y) { return hit }
        let cocoaY = primaryHeight - cgPoint.y
        return copyElement(in: app, x: cgPoint.x, y: cocoaY)
    }

    private static func copyElement(in app: AXUIElement, x: CGFloat, y: CGFloat) -> AXUIElement? {
        var ref: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &ref) == .success else { return nil }
        return ref
    }

    private static func nodesEqual(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        CFEqual(a, b)
    }

    // MARK: - AX helpers

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        elements(element, attribute: kAXVisibleChildrenAttribute)
            ?? elements(element, attribute: kAXChildrenAttribute)
            ?? []
    }

    private static func rect(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = value(element, attribute: kAXPositionAttribute),
              let sizeValue = value(element, attribute: kAXSizeAttribute)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func role(_ element: AXUIElement) -> String? {
        string(element, attribute: kAXRoleAttribute)
    }

    private static func subrole(_ element: AXUIElement) -> String? {
        string(element, attribute: kAXSubroleAttribute)
    }

    private static func elements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func child(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func string(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func value(_ element: AXUIElement, attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}
