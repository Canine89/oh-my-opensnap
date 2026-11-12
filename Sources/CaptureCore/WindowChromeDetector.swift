import AppKit
import ApplicationServices

/// 접근성 트리 조회 추상화. 실제 `AXUIElement`와 단위 테스트용 가짜 트리가 같은 측정 로직을 공유한다.
protocol WindowChromeNodeProvider {
    associatedtype Node
    func rect(of node: Node) -> CGRect?
    func role(of node: Node) -> String?
    func subrole(of node: Node) -> String?
    func children(of node: Node) -> [Node]
}

/// 다른 앱 창의 상단 헤더(타이틀바·툴바·탭바·패널 바) 높이를 잰다.
///
/// 다른 앱이 공개한 접근성 역할과 실제 프레임을 함께 읽는다. 따라서 브라우저,
/// 터미널, 네이티브 앱, Electron 앱에서 앱 이름별 고정 높이에 의존하지 않는다.
/// 본문은 창을 가로지르는 실제 콘텐츠 컨테이너(웹 영역·스크롤 영역·터미널 영역 등 —
/// 좌우 분할 창 포함)의 시작점으로 정하고, 그 위는 전부 헤더다.
enum WindowChromeDetector {
    /// 접근성 트리에서 읽은 상단 헤더 측정치.
    struct Measurement: Equatable {
        /// CG 전역 좌표 창 프레임 상단에서 잘라낼 높이(point).
        let inset: CGFloat
        /// 실제 본문 컨테이너(`AXWebArea`·`AXScrollArea`·`AXTextArea` 등)의 시작점이라
        /// 그 아래에 추가 툴바가 없다고 확신할 수 있으면 `true`.
        /// 신호등 대칭 높이나 최상단 래퍼 분할만 읽은 경우에는 `false` —
        /// 호출자가 픽셀 경계(`HeaderEdgeRefiner`)로 아래쪽 추가 툴바까지 확장할 수 있다.
        let isAuthoritative: Bool
    }

    /// 단위 테스트용 메모리 트리 노드.
    struct TestNode {
        let frame: CGRect?
        let role: String?
        let subrole: String?
        let children: [TestNode]

        init(frame: CGRect?,
             role: String?,
             subrole: String? = nil,
             children: [TestNode] = []) {
            self.frame = frame
            self.role = role
            self.subrole = subrole
            self.children = children
        }
    }

    private struct TestNodeProvider: WindowChromeNodeProvider {
        func rect(of node: TestNode) -> CGRect? { node.frame }
        func role(of node: TestNode) -> String? { node.role }
        func subrole(of node: TestNode) -> String? { node.subrole }
        func children(of node: TestNode) -> [TestNode] { node.children }
    }

    private struct AXNodeProvider: WindowChromeNodeProvider {
        func rect(of node: AXUIElement) -> CGRect? { WindowChromeDetector.rect(node) }
        func role(of node: AXUIElement) -> String? { WindowChromeDetector.role(node) }
        func subrole(of node: AXUIElement) -> String? { WindowChromeDetector.subrole(node) }
        func children(of node: AXUIElement) -> [AXUIElement] { WindowChromeDetector.children(of: node) }
    }

    /// CG 전역 좌표 창 프레임에서 상단 헤더 측정치를 구한다.
    static func measure(pid: pid_t,
                        windowFrame: CGRect,
                        primaryHeight: CGFloat) -> Measurement? {
        let app = AXUIElementCreateApplication(pid)
        // 응답이 느린 앱이 호버 처리 큐 전체를 붙들지 않도록 한다.
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let match = matchingWindow(in: app, fullRect: windowFrame, primaryHeight: primaryHeight) else {
            return nil
        }
        return measure(window: match.element,
                       fullRect: windowFrame,
                       align: match.align,
                       provider: AXNodeProvider())
    }

    /// CG 전역 좌표 창 프레임에서 잘라낼 상단 헤더 높이(point).
    static func topInset(pid: pid_t,
                         windowFrame: CGRect,
                         primaryHeight: CGFloat) -> CGFloat? {
        measure(pid: pid, windowFrame: windowFrame, primaryHeight: primaryHeight)?.inset
    }

    /// 단위 테스트 진입점: 이미 정렬된 좌표계의 테스트 트리에서 헤더 높이를 측정한다.
    static func measure(testWindow: TestNode, fullRect: CGRect) -> Measurement? {
        measure(window: testWindow,
                fullRect: fullRect,
                align: { $0 },
                provider: TestNodeProvider())
    }

    static func measure<P: WindowChromeNodeProvider>(window: P.Node,
                                                     fullRect: CGRect,
                                                     align: (CGRect) -> CGRect,
                                                     provider: P) -> Measurement? {
        let maxHeader = min(220, fullRect.height * 0.45)
        guard maxHeader >= 20 else { return nil }

        // 1순위: 본문(웹 영역·스크롤 영역·터미널 텍스트 영역 등)이 시작되는 위치.
        // 좌우 분할 창처럼 개별 패널 폭이 좁아도 같은 높이에서 합산 폭이 창을 가로지르면 본문으로 인정한다.
        if let contentStart = primaryContentTopInset(in: window,
                                                     fullRect: fullRect,
                                                     maxHeader: maxHeader,
                                                     align: align,
                                                     provider: provider) {
            return Measurement(inset: contentStart, isAuthoritative: true)
        }

        // 2순위: 툴바·탭 그룹·최상단 래퍼 분할·신호등 대칭 높이로부터 최소 헤더 경계를 구한다.
        // Electron/Chromium처럼 내부 DOM을 노출하지 않는 앱에서는 최소 보장선 역할을 하며,
        // 호출자가 정지 화면 픽셀 경계로 아래쪽 툴바를 추가로 탐색한다.
        if let minChrome = chromeMinimumInset(in: window,
                                              fullRect: fullRect,
                                              maxHeader: maxHeader,
                                              align: align,
                                              provider: provider) {
            return Measurement(inset: minChrome, isAuthoritative: false)
        }

        return nil
    }

    // MARK: - Window match

    private static func matchingWindow(in app: AXUIElement,
                                       fullRect: CGRect,
                                       primaryHeight: CGFloat) -> (element: AXUIElement, align: (CGRect) -> CGRect)? {
        let windows = elements(app, attribute: kAXWindowsAttribute) ?? []
        let matched = windows.compactMap { element -> (AXUIElement, CGFloat, (CGRect) -> CGRect)? in
            guard let raw = rect(element) else { return nil }
            let align = aligner(windowRaw: raw, fullRect: fullRect, primaryHeight: primaryHeight)
            return (element, ScreenGeometry.frameDelta(align(raw), fullRect), align)
        }
        .filter { $0.1 < 160 }
        .min { $0.1 < $1.1 }

        if let matched { return (matched.0, matched.2) }

        // 일부 Chromium/Electron 앱은 AXWindows 목록을 비워 두지만 focused/main
        // window는 제공한다. 후보 창 프레임과 충분히 같은 경우에만 쓰므로, 뒤에
        // 가려진 다른 창의 구조를 잘못 적용하지 않는다.
        let fallbackAttributes = [kAXFocusedWindowAttribute, kAXMainWindowAttribute]
        for attribute in fallbackAttributes {
            guard let element = child(app, attribute: attribute), let raw = rect(element) else { continue }
            let align = aligner(windowRaw: raw, fullRect: fullRect, primaryHeight: primaryHeight)
            guard ScreenGeometry.frameDelta(align(raw), fullRect) < 160 else { continue }
            return (element, align)
        }
        return nil
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

    // MARK: - Content start

    /// 창을 가로지르는 본문 영역(단일 또는 좌우 분할 패널 묶음)의 상단 = 앱 헤더가 끝나는 지점.
    private static func primaryContentTopInset<P: WindowChromeNodeProvider>(
        in window: P.Node,
        fullRect: CGRect,
        maxHeader: CGFloat,
        align: (CGRect) -> CGRect,
        provider: P
    ) -> CGFloat? {
        var candidates: [CGRect] = []
        let minSingleWidth = min(80, fullRect.width * 0.22)

        var remainingNodes = 800
        func walk(_ root: P.Node, depth: Int) {
            guard depth <= 12, remainingNodes > 0 else { return }
            for child in provider.children(of: root) {
                remainingNodes -= 1
                guard remainingNodes >= 0 else { return }
                guard let raw = provider.rect(of: child) else { continue }
                let frame = align(raw).intersection(fullRect)
                guard !frame.isNull, frame.width > 2, frame.height > 2 else { continue }

                let childRole = provider.role(of: child)
                if isPrimaryContentRole(childRole) {
                    // 본문 후보 자체는 더 파고들지 않는다. 웹 페이지 DOM처럼 방대한 하위
                    // 트리를 훑을 필요가 없고, 안쪽 요소는 어차피 더 아래에서 시작한다.
                    let heightRatio = frame.height / max(fullRect.height, 1)
                    let top = frame.minY - fullRect.minY
                    if frame.width >= minSingleWidth, heightRatio >= 0.25, top >= 20, top <= maxHeader {
                        candidates.append(frame)
                    }
                    continue
                }

                // SwiftUI AXHostingView나 Electron 래퍼처럼 창을 덮는 컨테이너를 따라 내려간다.
                let coversWindow = frame.height >= fullRect.height * 0.45
                    && frame.width >= fullRect.width * 0.45
                if isContainer(childRole) || coversWindow {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(window, depth: 0)
        guard !candidates.isEmpty else { return nil }

        // 같은 상단 높이(±4pt)에서 시작하는 분할 패널들의 가로 폭을 합쳐 평가한다.
        // 단독 좁은 사이드바(< 55%)는 걸러지고, Rex·iTerm·Xcode처럼 좌우로 나뉜 본문은 합산 폭으로 통과한다.
        let sorted = candidates.sorted { $0.minY < $1.minY }
        var clusters: [[CGRect]] = []
        for rect in sorted {
            if let lastAnchor = clusters.last?.first, rect.minY - lastAnchor.minY <= 4 {
                clusters[clusters.count - 1].append(rect)
            } else {
                clusters.append([rect])
            }
        }

        var best: (top: CGFloat, score: CGFloat)?
        for cluster in clusters {
            let combinedWidth = mergedHorizontalSpan(of: cluster, gapTolerance: 16)
            let widthRatio = combinedWidth / max(fullRect.width, 1)
            let maxHeightRatio = cluster.map { $0.height / max(fullRect.height, 1) }.max() ?? 0
            guard widthRatio >= 0.55, maxHeightRatio >= 0.28 else { continue }

            let top = (cluster.map(\.minY).min() ?? fullRect.minY) - fullRect.minY
            guard top >= 20, top <= maxHeader else { continue }
            let score = widthRatio * 2 + min(maxHeightRatio, 1)
            if best == nil || top < best!.top - 2 || (abs(top - best!.top) <= 2 && score > best!.score) {
                best = (top, score)
            }
        }
        return best?.top
    }

    private static func mergedHorizontalSpan(of rects: [CGRect], gapTolerance: CGFloat) -> CGFloat {
        let intervals = rects
            .map { (minX: $0.minX, maxX: $0.maxX) }
            .sorted { $0.minX < $1.minX }
        guard var current = intervals.first else { return 0 }
        var total: CGFloat = 0
        for next in intervals.dropFirst() {
            if next.minX <= current.maxX + gapTolerance {
                current.maxX = max(current.maxX, next.maxX)
            } else {
                total += max(0, current.maxX - current.minX)
                current = next
            }
        }
        total += max(0, current.maxX - current.minX)
        return total
    }

    private static func isPrimaryContentRole(_ role: String?) -> Bool {
        switch role {
        case "AXWebArea", kAXScrollAreaRole, kAXTextAreaRole, kAXTableRole, kAXOutlineRole, kAXListRole:
            return true
        default:
            return false
        }
    }

    // MARK: - Minimum chrome bound from the window tree

    private static func chromeMinimumInset<P: WindowChromeNodeProvider>(
        in window: P.Node,
        fullRect: CGRect,
        maxHeader: CGFloat,
        align: (CGRect) -> CGRect,
        provider: P
    ) -> CGFloat? {
        var insets: [CGFloat] = []
        var remainingNodes = 400

        func collect(in root: P.Node, rootFrame: CGRect, depth: Int) {
            guard depth <= 10, remainingNodes > 0 else { return }
            let rootIsTopFlush = rootFrame.minY <= fullRect.minY + 4
                && rootFrame.width >= fullRect.width * 0.85
                && rootFrame.height >= fullRect.height * 0.85

            var items: [(node: P.Node, frame: CGRect, role: String?, subrole: String?)] = []
            for child in provider.children(of: root) {
                remainingNodes -= 1
                guard remainingNodes >= 0 else { break }
                guard let raw = provider.rect(of: child) else { continue }
                let frame = align(raw).intersection(fullRect)
                guard !frame.isNull, frame.width > 2, frame.height > 2 else { continue }
                items.append((child, frame, provider.role(of: child), provider.subrole(of: child)))
            }

            for item in items {
                let frame = item.frame
                let topOffset = frame.minY - fullRect.minY

                // 1) 신호등 버튼은 타이틀바/탭바 세로 중앙에 배치된다.
                // 버튼의 하단(maxY)만 쓰면 아래쪽 여백(8~18pt)을 잘라 타이틀바를 관통하므로
                // 위쪽 여백만큼 아래쪽 여백을 대칭으로 더해 실제 타이틀바/탭바 높이를 구한다.
                if isTrafficLight(role: item.role, subrole: item.subrole) {
                    if topOffset >= 2, topOffset <= 36,
                       frame.minX - fullRect.minX <= 180,
                       frame.height >= 10, frame.height <= 26 {
                        let symmetricInset = (frame.maxY - fullRect.minY) + min(topOffset, 20)
                        insets.append(symmetricInset)
                    }
                    continue
                }

                // 2) 명시적 툴바·탭 그룹(탭바 아래 2단 툴바까지 포함).
                if isChromeRole(item.role, subrole: item.subrole),
                   topOffset <= 96,
                   frame.width >= fullRect.width * 0.45,
                   frame.height <= 200 {
                    insets.append(frame.maxY - fullRect.minY)
                }

                // 3) 창 상단에 맞닿은 전체 래퍼가 [상단 헤더 + 하단 본문 컨테이너]로 나뉘는 지점.
                if rootIsTopFlush {
                    if frame.width >= fullRect.width * 0.75,
                       frame.height >= fullRect.height * 0.55,
                       topOffset >= 20, topOffset <= maxHeader {
                        insets.append(topOffset)
                    } else if item.role == kAXGroupRole,
                              topOffset <= 12,
                              frame.width >= fullRect.width * 0.45,
                              frame.height >= 20, frame.height <= 120 {
                        let hasBodySibling = items.contains { sibling in
                            sibling.frame.minY >= frame.maxY - 6
                                && sibling.frame.minY <= frame.maxY + 12
                                && sibling.frame.height >= fullRect.height * 0.45
                                && sibling.frame.width >= fullRect.width * 0.5
                        }
                        if hasBodySibling {
                            insets.append(frame.maxY - fullRect.minY)
                        }
                    }
                }

                // 창 전체를 감싸는 패스스루 래퍼(Electron·SwiftUI 등)는 안쪽 분할까지 내려간다.
                let isTopFlushWrapper = topOffset <= 4
                    && frame.width >= fullRect.width * 0.85
                    && frame.height >= fullRect.height * 0.85
                if isTopFlushWrapper {
                    collect(in: item.node, rootFrame: frame, depth: depth + 1)
                } else if depth < 3, isContainer(item.role), topOffset <= 96 {
                    collect(in: item.node, rootFrame: frame, depth: depth + 1)
                }
            }
        }

        collect(in: window, rootFrame: fullRect, depth: 0)
        return insets.filter { $0 >= 20 && $0 <= maxHeader }.max()
    }

    private static func isChromeRole(_ role: String?, subrole: String?) -> Bool {
        switch role {
        case kAXToolbarRole, kAXTabGroupRole, "AXTabGroup":
            return true
        case kAXGroupRole, kAXRadioGroupRole:
            return subrole == "AXTabGroup" || subrole == kAXTabGroupRole
        default:
            return false
        }
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
        role == kAXGroupRole
            || role == kAXSplitGroupRole
            || role == kAXTabGroupRole
            || role == "AXLayoutArea"
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
