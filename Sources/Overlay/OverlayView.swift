import AppKit
import ApplicationServices
import ScreenCaptureKit

/// 디밍 + 크로스헤어 + 확대경(루페) + 선택 사각형 + 윈도우 하이라이트를 그리는 뷰.
/// `isFlipped == true`라 좌상단 기준 point 좌표를 쓴다(픽셀 좌표와 동일 방향).
///
/// 인터랙션 분기:
/// - 호버(버튼 안 누름): 커서 아래 윈도우를 자동 감지해 두 구역 중 하나를 하이라이트.
///   헤더(타이틀바·툴바·탭·주소표시줄) 위면 창 전체, 본문 위면 본문만 선택한다.
///   구역 경계는 창 구조로만 정하며 커서가 창에 들어온 위치와 무관하다.
/// - 클릭/드래그로 영역 선택 → 조정 단계로 진입(점선 테두리 + 핸들 8개)
/// - 조정 단계: 핸들 드래그로 크기 조절(루페 표시), 내부 드래그로 이동,
///   바깥 드래그로 새 선택, ⏎(Return)/더블클릭으로 캡처 확정
final class OverlayView: NSView {

    /// 창 하나의 헤더/본문 경계. 창 구조 측정이 끝나면 `isPrecise`가 true가 된다.
    private struct HoverCache {
        let windowID: CGWindowID
        let globalFrame: CGRect
        let localFullRect: CGRect
        let localContentRect: CGRect
        let isPrecise: Bool

        /// 본문 위의 헤더 띠. 경계를 못 나눴으면 높이 0.
        var localHeaderRect: CGRect {
            CGRect(x: localFullRect.minX,
                   y: localFullRect.minY,
                   width: localFullRect.width,
                   height: max(0, localContentRect.minY - localFullRect.minY))
        }
    }

    struct WindowSelection {
        let window: SCWindow
        let rect: CGRect
        let fullRect: CGRect
        let displayID: CGDirectDisplayID
    }

    // OverlayController가 주입
    var scale: CGFloat = 1
    var displayID: CGDirectDisplayID = 0
    var cgOrigin: CGPoint = .zero          // 이 디스플레이의 CG 전역 좌상단 원점(point)
    /// 캡처 모드 진입 순간의 정지 화면. 있으면 루페도 라이브 스트림 대신 여기서 샘플링해
    /// 배경(정지)과 확대경(라이브)이 서로 다른 프레임을 보여 주는 일이 없게 한다.
    var frozenImage: CGImage?
    weak var provider: DisplayStreamProvider?
    weak var hitTester: WindowHitTester?
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onWindowCapture: ((WindowSelection) -> Void)?
    /// 선택이 조정(확정 대기) 단계로 처음 들어갈 때 호출 —
    /// 컨트롤러가 커서를 되살리고 워치독을 해제하는 데 쓴다.
    var onAdjustingStarted: (() -> Void)?
    /// 이 뷰에서 새 선택이 시작될 때 호출 —
    /// 컨트롤러가 다른 디스플레이의 진행 중 선택을 비활성화한다.
    var onSelectionActivity: (() -> Void)?
    /// 조정 단계에서 크기 조절/이동이 끝날 때마다 호출 — 컨트롤러가 선택 HUD 위치를 따라 옮긴다.
    var onSelectionChanged: ((CGRect) -> Void)?
    /// ⏎/더블클릭 확정 허용 여부. 선택 HUD가 결정을 맡는 모드에선 꺼서 이중 확정을 막는다.
    var confirmEnabled = true
    /// 조정 단계 안내 문구. 확정 방식(⏎ vs 선택 HUD)이 모드마다 달라 컨트롤러가 채운다.
    var adjustingHint = "드래그 조절 · ⏎ 캡처 · Esc 취소"
    private let idleHint = "드래그 영역 선택 · 클릭 창 캡처 · Esc 취소"

    // MARK: 상태 기계
    /// 크기 조절 핸들 8개. 배열 순서가 히트 테스트 우선순위라 코너가 변 중앙보다 먼저다.
    private enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right

        var cursor: NSCursor {
            switch self {
            case .topLeft: return .frameResize(position: .topLeft, directions: .all)
            case .topRight: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            case .top: return .frameResize(position: .top, directions: .all)
            case .bottom: return .frameResize(position: .bottom, directions: .all)
            case .left: return .frameResize(position: .left, directions: .all)
            case .right: return .frameResize(position: .right, directions: .all)
            }
        }
    }

    private enum Phase {
        case idle               // 호버 — 윈도우 하이라이트
        case selecting          // 첫 드래그로 사각형 그리는 중
        case adjusting          // 선택 확정 대기 — 점선 + 핸들, ⏎/더블클릭으로 캡처
        case resizing(Handle)   // 핸들 드래그로 크기 조절 중 (루페 표시)
        case moving             // 선택 영역 내부 드래그로 이동 중
    }

    private var phase: Phase = .idle
    /// 조정 단계(핸들 드래그/이동 포함) 여부 — 점선·핸들·짙은 디밍을 그릴지 결정.
    private var selectionLocked: Bool {
        switch phase {
        case .adjusting, .resizing, .moving: return true
        case .idle, .selecting: return false
        }
    }

    private var cursor: CGPoint = .zero
    private var dragStart: CGPoint?
    private var downPoint: CGPoint = .zero
    private var selection: CGRect?
    private var windowSelection: WindowSelection?
    private var previousSelection: CGRect?   // 조정 중 빈 클릭/미세 드래그 시 복원용
    private var previousWindowSelection: WindowSelection?
    private var resizeBase: CGRect = .zero   // 핸들 드래그 시작 시점의 선택(앵커 계산용)
    private var moveOffset: CGPoint = .zero
    private var cursorInside = false
    private var didDrag = false
    private var suppressed = false           // 다른 디스플레이에서 선택 진행 중 → 이 뷰의 표시 억제
    private var dashPhase: CGFloat = 0       // 점선 행진(marching ants) 위상
    private let dragThreshold: CGFloat = 5
    private let handleHitRadius: CGFloat = 12
    private let handleRadius: CGFloat = 4.5

    // 호버 중 감지된 윈도우
    private var hoveredWindow: SCWindow?
    private var hoveredWindowRect: CGRect?     // 클릭 시 선택될 영역. 이 뷰의 로컬 좌표(좌상단 기준)
    private var hoveredFullWindowRect: CGRect? // 실제 윈도우 전체 영역. 헤더/본문 구분 가이드용.
    /// 캡처 세션 동안 창별 경계를 기억한다. 창 사이를 오가도 같은 창은 같은 경계를 보여 준다.
    private var hoverCaches: [CGWindowID: HoverCache] = [:]
    private let accessibilityQueue = DispatchQueue(label: "com.goldenrabbit.ohmyopensnap.accessibility-hover", qos: .userInitiated)
    private var pendingAccessibilityWindowIDs: Set<CGWindowID> = []

    // 화면 안내(힌트) 상태 — 단계가 바뀔 때마다 잠깐 보였다가 사라진다.
    private var hintShownAt = Date()
    private var hintRect: CGRect = .zero
    private let hintHold: TimeInterval = 2.6
    private let hintFade: TimeInterval = 0.5
    private var appIconCache: [pid_t: NSImage] = [:]

    // 루페 렌더 상태
    private let loupeRadius = 22                 // 한 변 45px 소스 영역
    private let loupeSize: CGFloat = 184
    private var loupeDirtyFrame: CGRect = .zero
    private var lastColor: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    /// 오버레이가 막 떠서 아직 창이 활성(key)이 아니어도 첫 클릭을 그대로 받는다.
    /// (이게 없으면 첫 클릭이 '창 활성화용'으로 먹혀, 두 번 클릭해야 선택이 시작된다.)
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 트래킹
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }

    /// 이 디스플레이의 루페 스트림을 켜 달라고 컨트롤러에 알린다.
    /// (커서가 있는 화면만 스트림해 CPU/GPU를 줄인다.)
    var onBecomeActiveDisplay: (() -> Void)?

    override func mouseExited(with event: NSEvent) { cursorInside = false; needsDisplay = true }

    /// 오버레이가 막 떠서 아직 마우스 이벤트가 오기 전, 현재 커서 위치로 초기화한다.
    /// 커서가 이 디스플레이 위에 있을 때만 표시를 켠다(멀티 디스플레이 대응).
    func primeCursor() {
        guard let window else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(local) else { return }
        cursor = local
        cursorInside = true
        hintShownAt = Date()
        onBecomeActiveDisplay?()
        updateHoveredWindow()
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        // 진입 이벤트에도 실제 위치를 반영해야 첫 mouseMoved 전 (0,0) 크로스헤어가 안 보인다.
        cursor = convert(event.locationInWindow, from: nil)
        cursorInside = true
        onBecomeActiveDisplay?()
        if !selectionLocked, !suppressed { updateHoveredWindow() }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        cursorInside = true
        onBecomeActiveDisplay?()
        if selectionLocked {
            // 조정 단계에선 크로스헤어 대신 위치별 커서 모양으로 피드백한다.
            updateAdjustCursor(at: cursor)
            return
        }
        if !suppressed { updateHoveredWindow() }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        downPoint = point

        if selectionLocked {
            if let handle = handle(at: point) {
                resizeBase = selection ?? .zero
                phase = .resizing(handle)
            } else if let sel = selection, sel.contains(point) {
                moveOffset = CGPoint(x: point.x - sel.minX, y: point.y - sel.minY)
                phase = .moving
                NSCursor.closedHand.set()
            } else {
                // 선택 바깥 → 새 선택 시작. 클릭만 하고 떼면 기존 선택을 복원한다.
                previousSelection = selection
                previousWindowSelection = windowSelection
                beginSelecting(at: point)
            }
        } else {
            beginSelecting(at: point)
        }
        needsDisplay = true
    }

    private func beginSelecting(at point: CGPoint) {
        suppressed = false
        onSelectionActivity?()
        phase = .selecting
        dragStart = point
        didDrag = false
        selection = CGRect(origin: point, size: .zero)
        windowSelection = nil
        NSCursor.crosshair.set()   // 커서가 이미 보이는 상태(조정 후 재선택)일 때를 위해
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        let square = event.modifierFlags.contains(.shift)

        switch phase {
        case .selecting:
            if let start = dragStart {
                if hypot(point.x - start.x, point.y - start.y) >= dragThreshold { didDrag = true }
                selection = makeRect(start, point, square: square)
                if didDrag { windowSelection = nil }
            }
        case .resizing(let handle):
            // 화면 밖으로 못 나가게 클램프 — 선택이 디스플레이를 벗어나는 걸 막는다.
            let clamped = CGPoint(x: max(0, min(point.x, bounds.width)),
                                  y: max(0, min(point.y, bounds.height)))
            selection = resize(resizeBase, handle: handle, to: clamped, square: square)
            if let sel = selection { onSelectionChanged?(sel) }   // HUD가 실시간으로 따라오게
        case .moving:
            if let sel = selection {
                var origin = CGPoint(x: point.x - moveOffset.x, y: point.y - moveOffset.y)
                origin.x = max(0, min(origin.x, bounds.width - sel.width))
                origin.y = max(0, min(origin.y, bounds.height - sel.height))
                let moved = CGRect(origin: origin, size: sel.size)
                selection = moved
                onSelectionChanged?(moved)                        // HUD가 실시간으로 따라오게
            }
        case .idle, .adjusting:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch phase {
        case .selecting:
            defer { dragStart = nil; didDrag = false; previousSelection = nil; previousWindowSelection = nil }
            guard let start = dragStart else { phase = .idle; needsDisplay = true; return }

            if didDrag {
                let rect = makeRect(start, point, square: event.modifierFlags.contains(.shift))
                if rect.width > 2, rect.height > 2 {
                    selection = rect
                    enterAdjusting()
                } else if let previous = previousSelection {
                    selection = previous            // 미세 드래그 → 기존 선택 유지
                    windowSelection = previousWindowSelection
                    enterAdjusting()
                } else {
                    onCancel?()
                    return
                }
            } else if let previous = previousSelection {
                selection = previous                // 조정 중 바깥 빈 클릭 → 기존 선택 유지
                windowSelection = previousWindowSelection
                enterAdjusting()
            } else if let hoveredWindow, let windowRect = hoveredWindowRect {
                // 클릭(드래그 없음) + 감지된 윈도우 → 그 윈도우 영역을 조정 가능한 선택으로 전환.
                selectInitialRegion(windowRect, windowSelection: windowSelection(for: hoveredWindow, rect: windowRect))
            } else {
                onCancel?()
                return
            }
        case .resizing:
            phase = .adjusting
            if let sel = selection { onSelectionChanged?(sel) }
        case .moving:
            let moved = hypot(point.x - downPoint.x, point.y - downPoint.y) >= dragThreshold
            if event.clickCount == 2, !moved, confirmEnabled {
                confirmSelection()                  // 내부 더블클릭 → 캡처 확정
                return
            }
            phase = .adjusting
            if let sel = selection { onSelectionChanged?(sel) }
        case .idle, .adjusting:
            break
        }
        needsDisplay = true
        if selectionLocked { updateAdjustCursor(at: point) }
    }

    private func selectInitialRegion(_ rect: CGRect, windowSelection: WindowSelection?) {
        let clipped = rect.intersection(bounds)
        guard clipped.width > 2, clipped.height > 2 else { return }
        selection = clipped
        self.windowSelection = windowSelection
        phase = .adjusting
        hintShownAt = Date()
        onAdjustingStarted?()
        onSelectionChanged?(clipped)
    }

    /// 선택 확정 대기 단계로 진입. 커서 복구/워치독 해제는 컨트롤러 콜백이 맡는다.
    private func enterAdjusting() {
        phase = .adjusting
        hintShownAt = Date()
        onAdjustingStarted?()
        window?.makeFirstResponder(self)   // ⏎ 키를 받기 위해
        updateAdjustCursor(at: cursor)
        needsDisplay = true
    }

    /// 조정 단계(드래그 중 포함)의 현재 선택. 컨트롤러가 HUD 확정 시점에 읽는다.
    var currentSelection: CGRect? {
        selectionLocked ? selection : nil
    }

    var currentWindowSelection: WindowSelection? {
        guard selectionLocked,
              let selection,
              let windowSelection,
              contains(windowSelection.fullRect, selection)
        else { return nil }
        return WindowSelection(window: windowSelection.window,
                               rect: selection,
                               fullRect: windowSelection.fullRect,
                               displayID: displayID)
    }

    /// 조정 단계라면 현재 선택으로 캡처를 확정한다. (⏎ 모니터/키 입력에서 호출)
    @discardableResult
    func confirmIfAdjusting() -> Bool {
        guard confirmEnabled, case .adjusting = phase else { return false }
        confirmSelection()
        return true
    }

    private func confirmSelection() {
        guard let sel = selection, sel.width > 2, sel.height > 2 else { return }
        if let windowSelection = currentWindowSelection {
            phase = .idle
            onWindowCapture?(windowSelection)
            return
        }
        phase = .idle
        onFinish?(sel)
    }

    /// 다른 디스플레이에서 선택이 시작되면 이 뷰의 선택/표시를 비활성화한다.
    func deactivateSelection() {
        suppressed = true
        phase = .idle
        selection = nil
        windowSelection = nil
        previousSelection = nil
        previousWindowSelection = nil
        dragStart = nil
        didDrag = false
        needsDisplay = true
    }

    private func updateAdjustCursor(at point: CGPoint) {
        guard case .adjusting = phase else { return }
        if let handle = handle(at: point) {
            handle.cursor.set()
        } else if let sel = selection, sel.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func updateHoveredWindow() {
        guard let hitTester else { clearHoveredWindow(); return }
        let globalPoint = CGPoint(x: cgOrigin.x + cursor.x, y: cgOrigin.y + cursor.y)
        if let candidate = hitTester.window(at: globalPoint) {
            hoveredWindow = candidate.scWindow
            let cached = cachedHoverRegion(for: candidate)
            hoveredFullWindowRect = cached.localFullRect

            // 두 구역뿐이다: 헤더 위면 창 전체, 그 외엔 본문.
            let headerRect = cached.localHeaderRect
            if headerRect.height > 0, headerRect.contains(cursor) {
                hoveredWindowRect = cached.localFullRect
            } else {
                hoveredWindowRect = cached.localContentRect
            }
        } else {
            clearHoveredWindow()
        }
    }

    private func windowSelection(for window: SCWindow, rect: CGRect) -> WindowSelection? {
        guard let full = hoveredFullWindowRect
        else { return nil }
        let clipped = rect.intersection(bounds)
        let clippedFull = full.intersection(bounds)
        guard contains(clippedFull, clipped) else { return nil }
        return WindowSelection(window: window, rect: clipped, fullRect: clippedFull, displayID: displayID)
    }

    private func contains(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 1.5) -> Bool {
        inner.minX >= outer.minX - tolerance
            && inner.minY >= outer.minY - tolerance
            && inner.maxX <= outer.maxX + tolerance
            && inner.maxY <= outer.maxY + tolerance
    }

    private func clearHoveredWindow() {
        hoveredWindow = nil
        hoveredWindowRect = nil
        hoveredFullWindowRect = nil
    }

    private func cachedHoverRegion(for candidate: WindowCandidate) -> HoverCache {
        let windowID = candidate.scWindow.windowID
        if let cache = hoverCaches[windowID], cache.globalFrame == candidate.cgFrame {
            return cache
        }

        let fullRect = localRect(fromGlobal: candidate.cgFrame)
        let content = contentRect(for: candidate.scWindow, localFullRect: fullRect)
        let next = HoverCache(windowID: windowID,
                              globalFrame: candidate.cgFrame,
                              localFullRect: fullRect,
                              localContentRect: content,
                              isPrecise: false)
        hoverCaches[windowID] = next
        scheduleContentRefinement(for: candidate, localFullRect: fullRect)
        return next
    }

    private func localRect(fromGlobal rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - cgOrigin.x,
               y: rect.minY - cgOrigin.y,
               width: rect.width,
               height: rect.height)
    }

    private func contentRect(for window: SCWindow, localFullRect: CGRect) -> CGRect {
        Self.contentRect(from: localFullRect, topInset: fallbackChromeTopInset(for: window, windowHeight: localFullRect.height))
    }

    private static func contentRect(from fullRect: CGRect, topInset: CGFloat) -> CGRect {
        guard topInset > 0, fullRect.height - topInset >= 40 else { return fullRect }
        return CGRect(x: fullRect.minX,
                      y: fullRect.minY + topInset,
                      width: fullRect.width,
                      height: fullRect.height - topInset)
    }

    /// 창 구조(접근성)로 헤더 높이를 재고, 못 재면 앱별 추정값을 정지 화면의 실제
    /// 경계선에 맞춘다. 결과는 창 구조에만 의존하므로 커서 위치는 넘기지 않는다.
    private func scheduleContentRefinement(for candidate: WindowCandidate, localFullRect: CGRect) {
        let windowID = candidate.scWindow.windowID
        guard !pendingAccessibilityWindowIDs.contains(windowID),
              let pid = candidate.scWindow.owningApplication?.processID
        else { return }

        pendingAccessibilityWindowIDs.insert(windowID)
        let globalFrame = candidate.cgFrame
        let primaryHeight = ScreenGeometry.primaryHeight
        let fallbackInset = fallbackChromeTopInset(for: candidate.scWindow, windowHeight: localFullRect.height)
        let snapshot = frozenImage
        let snapshotScale = self.scale

        accessibilityQueue.async { [weak self] in
            let measured = AccessibilityPermission.isGranted
                ? WindowChromeDetector.topInset(pid: pid,
                                                windowFrame: globalFrame,
                                                primaryHeight: primaryHeight)
                : nil
            let refined = measured == nil && fallbackInset > 0
                ? snapshot.flatMap {
                    HeaderEdgeRefiner.refine(in: $0,
                                             windowRect: localFullRect,
                                             candidateInset: fallbackInset,
                                             tolerance: 40,
                                             scale: snapshotScale)
                }
                : nil
            let inset = measured ?? refined ?? fallbackInset
            let content = Self.contentRect(from: localFullRect, topInset: inset)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingAccessibilityWindowIDs.remove(windowID)
                guard let cache = self.hoverCaches[windowID], cache.globalFrame == globalFrame else { return }

                self.hoverCaches[windowID] = HoverCache(windowID: windowID,
                                                        globalFrame: globalFrame,
                                                        localFullRect: localFullRect,
                                                        localContentRect: content,
                                                        isPrecise: measured != nil || refined != nil)
                if !self.selectionLocked, !self.suppressed {
                    self.updateHoveredWindow()
                    self.needsDisplay = true
                }
            }
        }
    }

    private func fallbackChromeTopInset(for window: SCWindow, windowHeight: CGFloat) -> CGFloat {
        guard windowHeight >= 120 else { return 0 }
        let bundleID = (window.owningApplication?.bundleIdentifier ?? "").lowercased()
        let appName = (window.owningApplication?.applicationName ?? "").lowercased()

        let preferred: CGFloat
        if bundleID.contains("com.apple.safari") {
            preferred = 108
        } else if bundleID.contains("com.google.chrome") || bundleID.contains("com.microsoft.edgemac") || bundleID.contains("org.mozilla.firefox") {
            preferred = 124
        } else if bundleID.contains("com.brave.browser") || bundleID.contains("com.operasoftware.opera") || bundleID.contains("company.thebrowser.browser") {
            preferred = 124
        } else if bundleID.contains("com.apple.finder") {
            preferred = 72
        } else if bundleID.contains("com.apple.dt.xcode") {
            preferred = 104
        } else if isVSCodeFamily(bundleID: bundleID, appName: appName) {
            // custom titlebar 35 + tabs 35. 78은 브레드크럼/에디터를 가로지른다.
            preferred = 70
        } else if bundleID.contains("com.kakao.kakaotalk") || bundleID.contains("com.kakao.talk") {
            // 네이티브 타이틀바(~28) + 대화방 헤더. 32만 빼면 프로필/검색 줄을 관통한다.
            preferred = 88
        } else if bundleID.contains("com.apple.terminal") || bundleID.contains("com.googlecode.iterm2") {
            preferred = 34
        } else if bundleID.contains("com.apple.preview") {
            preferred = 64
        } else {
            // Tahoe 기본 타이틀바(~32pt). 접근성이 헤더를 재기 전에도 헤더/본문을 나눈다.
            preferred = 32
        }

        return min(preferred, windowHeight * 0.35)
    }

    private func isVSCodeFamily(bundleID: String, appName: String) -> Bool {
        bundleID.contains("com.microsoft.vscode")
            || bundleID.contains("com.todesktop")
            || bundleID.contains("vscodium")
            || bundleID.contains("cursor")
            || bundleID.contains("windsurf")
            || appName == "code"
            || appName == "cursor"
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()                       // Esc
        case 36, 76: confirmIfAdjusting()          // Return / 키패드 Enter
        default: break
        }
    }

    // 우클릭(또는 트랙패드 두 손가락 클릭)으로 언제든 취소. 키 입력이 오버레이로
    // 전달되지 않는 상황(앱이 key가 못 된 경우)에도 마우스 이벤트는 항상 도달하므로
    // 가장 확실한 취소 경로다.
    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    /// 타이머(30fps)가 호출 — 루페 픽셀 갱신 + 조정 단계 점선 행진 애니메이션.
    func tick() {
        refreshLoupe()
        let elapsed = Date().timeIntervalSince(hintShownAt)
        if hintRect != .zero, elapsed >= hintHold, elapsed <= hintHold + hintFade + 0.1 {
            setNeedsDisplay(hintRect.insetBy(dx: -2, dy: -2))
        }
        if selectionLocked, let sel = selection {
            dashPhase += 0.6
            if dashPhase >= 10 { dashPhase -= 10 }   // 점선 한 주기(6+4)
            invalidateBorder(sel)
        }
    }

    /// 타이머가 호출 — 커서가 멈춰 있어도 루페 픽셀을 갱신.
    /// 정지 화면에서는 커서가 움직일 때만 픽셀이 바뀌므로(마우스 이벤트가 이미 무효화한다) 건너뛴다.
    func refreshLoupe() {
        guard frozenImage == nil, cursorInside, loupeDirtyFrame != .zero else { return }
        setNeedsDisplay(loupeDirtyFrame)
    }

    /// 점선 애니메이션을 위해 테두리(핸들 포함) 띠 영역만 무효화 — 전체 리드로우를 피한다.
    private func invalidateBorder(_ sel: CGRect) {
        let pad: CGFloat = 8
        let outer = sel.insetBy(dx: -pad, dy: -pad)
        setNeedsDisplay(CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: pad * 2))
        setNeedsDisplay(CGRect(x: outer.minX, y: outer.maxY - pad * 2, width: outer.width, height: pad * 2))
        setNeedsDisplay(CGRect(x: outer.minX, y: outer.minY, width: pad * 2, height: outer.height))
        setNeedsDisplay(CGRect(x: outer.maxX - pad * 2, y: outer.minY, width: pad * 2, height: outer.height))
    }

    private func makeRect(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
        var w = b.x - a.x
        var h = b.y - a.y
        if square {
            let side = max(abs(w), abs(h))
            w = side * (w < 0 ? -1 : 1)
            h = side * (h < 0 ? -1 : 1)
        }
        return CGRect(x: min(a.x, a.x + w), y: min(a.y, a.y + h), width: abs(w), height: abs(h))
    }

    /// 핸들 드래그 시작 시점의 선택(base) 기준으로 새 사각형을 계산한다.
    /// 코너는 반대편 코너를 앵커로 자유 변형(Shift로 정사각형), 변 중앙은 해당 축만 움직인다.
    /// min/max로 계산하므로 반대편을 지나치면 자연스럽게 뒤집힌다.
    private func resize(_ base: CGRect, handle: Handle, to p: CGPoint, square: Bool) -> CGRect {
        switch handle {
        case .topLeft: return makeRect(CGPoint(x: base.maxX, y: base.maxY), p, square: square)
        case .topRight: return makeRect(CGPoint(x: base.minX, y: base.maxY), p, square: square)
        case .bottomLeft: return makeRect(CGPoint(x: base.maxX, y: base.minY), p, square: square)
        case .bottomRight: return makeRect(CGPoint(x: base.minX, y: base.minY), p, square: square)
        case .top:
            return CGRect(x: base.minX, y: min(p.y, base.maxY),
                          width: base.width, height: abs(base.maxY - p.y))
        case .bottom:
            return CGRect(x: base.minX, y: min(p.y, base.minY),
                          width: base.width, height: abs(p.y - base.minY))
        case .left:
            return CGRect(x: min(p.x, base.maxX), y: base.minY,
                          width: abs(base.maxX - p.x), height: base.height)
        case .right:
            return CGRect(x: min(p.x, base.minX), y: base.minY,
                          width: abs(p.x - base.minX), height: base.height)
        }
    }

    /// 핸들 8개의 중심 좌표. 코너 4개가 먼저라 작은 선택에서 코너가 변 중앙보다 우선 잡힌다.
    private func handleCenters(_ sel: CGRect) -> [(Handle, CGPoint)] {
        [(.topLeft, CGPoint(x: sel.minX, y: sel.minY)),
         (.topRight, CGPoint(x: sel.maxX, y: sel.minY)),
         (.bottomLeft, CGPoint(x: sel.minX, y: sel.maxY)),
         (.bottomRight, CGPoint(x: sel.maxX, y: sel.maxY)),
         (.top, CGPoint(x: sel.midX, y: sel.minY)),
         (.bottom, CGPoint(x: sel.midX, y: sel.maxY)),
         (.left, CGPoint(x: sel.minX, y: sel.midY)),
         (.right, CGPoint(x: sel.maxX, y: sel.midY))]
    }

    private func handle(at point: CGPoint) -> Handle? {
        guard let sel = selection else { return nil }
        return handleCenters(sel).first {
            hypot(point.x - $0.1.x, point.y - $0.1.y) <= handleHitRadius
        }?.0
    }

    // MARK: 그리기
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)

        let showSelection: Bool
        switch phase {
        case .selecting: showSelection = didDrag
        case .adjusting, .resizing, .moving: showSelection = true
        case .idle: showSelection = false
        }

        if showSelection, let sel = selection, sel.width > 0, sel.height > 0 {
            drawDimmedOverlay(excluding: sel)
            if selectionLocked {
                drawAdjustableSelection(sel)
            } else {
                NSColor.white.setStroke()
                let border = NSBezierPath(rect: sel)
                border.lineWidth = 1
                border.stroke()
            }
            drawDimensionLabel(for: sel)
        } else if case .idle = phase, !suppressed, let windowRect = hoveredWindowRect {
            drawDimmedOverlay(excluding: windowRect)
            drawWindowSelectionGuide(selectedRect: windowRect, fullRect: hoveredFullWindowRect, ctx)
            drawZoneLabel(for: windowRect, isFullWindow: windowRect == hoveredFullWindowRect)
        } else {
            drawDimmedOverlay(excluding: nil)
        }

        if cursorInside, !suppressed { drawHint() }

        // 크로스헤어/루페
        switch phase {
        case .idle, .selecting:
            guard cursorInside, !suppressed else { loupeDirtyFrame = .zero; return }
            drawCrosshair()
            drawLoupe(ctx)                                   // 창 스냅 중에도 항상 — 커서 위치와 픽셀 확인의 기준점
        case .resizing:
            drawLoupe(ctx)                                   // 핸들 조절 중 픽셀 단위 확인용 확대경
        case .adjusting, .moving:
            loupeDirtyFrame = .zero
        }
    }

    private func drawDimmedOverlay(excluding selectedRect: CGRect?) {
        let alpha: CGFloat = selectionLocked ? 0.56 : 0.32
        NSColor(white: 0, alpha: alpha).setFill()

        guard let selected = selectedRect?.intersection(bounds), !selected.isEmpty else {
            bounds.fill()
            return
        }

        let top = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: selected.minY - bounds.minY)
        let left = CGRect(x: bounds.minX, y: selected.minY, width: selected.minX - bounds.minX, height: selected.height)
        let right = CGRect(x: selected.maxX, y: selected.minY, width: bounds.maxX - selected.maxX, height: selected.height)
        let bottom = CGRect(x: bounds.minX, y: selected.maxY, width: bounds.width, height: bounds.maxY - selected.maxY)
        [top, left, right, bottom].forEach { rect in
            if rect.width > 0, rect.height > 0 { rect.fill() }
        }
    }

    /// 조정 단계의 선택 표시: 점선 테두리(행진 애니메이션) + 크기 조절 핸들 8개.
    private func drawAdjustableSelection(_ sel: CGRect) {
        // 점선이 밝은 배경 위에서도 보이도록 어두운 실선을 깔고 흰 점선을 겹친다.
        let underlay = NSBezierPath(rect: sel)
        underlay.lineWidth = 1
        NSColor(white: 0, alpha: 0.7).setStroke()
        underlay.stroke()

        let dashed = NSBezierPath(rect: sel)
        dashed.lineWidth = 1
        dashed.setLineDash([6, 4], count: 2, phase: dashPhase)
        NSColor.white.setStroke()
        dashed.stroke()

        for (_, center) in handleCenters(sel) {
            let rect = CGRect(x: center.x - handleRadius, y: center.y - handleRadius,
                              width: handleRadius * 2, height: handleRadius * 2)
            let knob = NSBezierPath(ovalIn: rect)
            NSColor.white.setFill()
            knob.fill()
            NSColor(white: 0, alpha: 0.55).setStroke()
            knob.lineWidth = 1
            knob.stroke()
        }
    }

    private func drawWindowHighlight(_ rect: CGRect, _ ctx: CGContext) {
        let clipped = rect.intersection(bounds)
        guard !clipped.isEmpty else { return }
        ctx.clear(clipped)                                   // 실제 윈도우가 비치도록 디밍 제거
        Brand.red.withAlphaComponent(0.10).setFill()
        NSBezierPath(rect: clipped).fill()                   // 클릭 가능 표시(연한 브랜드 레드)
        Brand.red.setStroke()
        let border = NSBezierPath(rect: clipped.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()
    }

    private func drawWindowSelectionGuide(selectedRect: CGRect, fullRect: CGRect?, _ ctx: CGContext) {
        if let full = fullRect?.intersection(bounds), !full.isEmpty, full != selectedRect.intersection(bounds) {
            Brand.red.withAlphaComponent(0.6).setStroke()
            let fullBorder = NSBezierPath(rect: full.insetBy(dx: 0.75, dy: 0.75))
            fullBorder.lineWidth = 1
            fullBorder.setLineDash([4, 4], count: 2, phase: 0)
            fullBorder.stroke()
        }
        drawWindowHighlight(selectedRect, ctx)
    }

    /// 크로스헤어: 픽셀에 정렬한 1px 흰 선 + 어두운 밑선(밝은 배경에서도 보임),
    /// 커서 중심은 비워 조준점의 픽셀을 가리지 않고, 작은 링으로 정확한 지점을 표시한다.
    private func drawCrosshair() {
        let x = floor(cursor.x) + 0.5
        let y = floor(cursor.y) + 0.5
        let gap: CGFloat = 7

        let lines = NSBezierPath()
        lines.move(to: CGPoint(x: x, y: 0));               lines.line(to: CGPoint(x: x, y: y - gap))
        lines.move(to: CGPoint(x: x, y: y + gap));         lines.line(to: CGPoint(x: x, y: bounds.height))
        lines.move(to: CGPoint(x: 0, y: y));               lines.line(to: CGPoint(x: x - gap, y: y))
        lines.move(to: CGPoint(x: x + gap, y: y));         lines.line(to: CGPoint(x: bounds.width, y: y))
        NSColor(white: 0, alpha: 0.32).setStroke(); lines.lineWidth = 3; lines.stroke()
        NSColor.white.withAlphaComponent(0.92).setStroke(); lines.lineWidth = 1; lines.stroke()

        let ring = NSBezierPath(ovalIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7))
        NSColor(white: 0, alpha: 0.45).setStroke(); ring.lineWidth = 2.5; ring.stroke()
        NSColor.white.setStroke(); ring.lineWidth = 1; ring.stroke()
    }

    /// 확대경: 앱의 HUD 표면과 같은 12pt 모서리·얇은 테두리, 중심 픽셀은 브랜드 레드,
    /// 아래에 색상·좌표 판독 알약(치수 라벨·구역 이름표와 같은 스타일).
    private func drawLoupe(_ ctx: CGContext) {
        let textHeight: CGFloat = 32
        let gap: CGFloat = 24

        var origin = CGPoint(x: cursor.x + gap, y: cursor.y + gap)
        if origin.x + loupeSize > bounds.width { origin.x = cursor.x - gap - loupeSize }
        if origin.y + loupeSize + textHeight > bounds.height { origin.y = cursor.y - gap - loupeSize - textHeight }
        origin.x = max(8, min(origin.x, bounds.width - loupeSize - 8))
        origin.y = max(8, min(origin.y, bounds.height - loupeSize - textHeight - 8))

        let frame = CGRect(origin: origin, size: CGSize(width: loupeSize, height: loupeSize))
        loupeDirtyFrame = CGRect(x: frame.minX - 4, y: frame.minY - 4,
                                 width: loupeSize + 8, height: loupeSize + textHeight + 8)

        // 배경
        let bg = NSBezierPath(roundedRect: frame, xRadius: Brand.cornerRadius, yRadius: Brand.cornerRadius)
        NSColor(white: 0.08, alpha: 0.94).setFill()
        bg.fill()

        // 정지 화면은 풀 해상도 그대로, 라이브 스트림은 축소되어 있으므로 bufferScale로 좌표를 맞춘다.
        let sampleScale = frozenImage != nil ? scale : (provider?.bufferScale ?? scale)
        let centerX = Int((cursor.x * sampleScale).rounded())
        let centerY = Int((cursor.y * sampleScale).rounded())
        let sampled: SampledRegion?
        if let frozenImage {
            sampled = PixelSampling.sample(frozenImage, centerX: centerX, centerY: centerY, radius: loupeRadius)
        } else if let buffer = provider?.latestBuffer() {
            sampled = PixelSampling.sample(buffer, centerX: centerX, centerY: centerY, radius: loupeRadius)
        } else {
            sampled = nil
        }
        if let region = sampled {
            ctx.saveGState()
            bg.addClip()
            // flipped 뷰에서 CGContext.draw는 상하 반전되므로, flip을 처리해 주는 NSImage로 그린다.
            NSGraphicsContext.current?.imageInterpolation = .none   // nearest-neighbor → 픽셀 격자 보임
            NSImage(cgImage: region.image, size: frame.size).draw(in: frame)
            ctx.restoreGState()
            lastColor = region.centerColor
        }

        let side = CGFloat(loupeRadius * 2 + 1)
        let pixelSize = loupeSize / side
        let cx = frame.midX, cy = frame.midY
        let pixelGap = pixelSize / 2

        // 중앙 십자선 — 캡처 시작 지점 표시 (중앙 픽셀 둘레는 비워 둠)
        ctx.saveGState()
        bg.addClip()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: frame.minX, y: cy)); cross.line(to: CGPoint(x: cx - pixelGap, y: cy))
        cross.move(to: CGPoint(x: cx + pixelGap, y: cy)); cross.line(to: CGPoint(x: frame.maxX, y: cy))
        cross.move(to: CGPoint(x: cx, y: frame.minY)); cross.line(to: CGPoint(x: cx, y: cy - pixelGap))
        cross.move(to: CGPoint(x: cx, y: cy + pixelGap)); cross.line(to: CGPoint(x: cx, y: frame.maxY))
        NSColor(white: 0, alpha: 0.45).setStroke(); cross.lineWidth = 3; cross.stroke()   // 가독성용 밑선
        NSColor.white.withAlphaComponent(0.9).setStroke(); cross.lineWidth = 1; cross.stroke()
        ctx.restoreGState()

        // 중앙 픽셀 하이라이트 — "빨간 프레임 = 잡히는 곳"과 같은 언어
        let highlight = CGRect(x: cx - pixelSize / 2, y: cy - pixelSize / 2,
                               width: pixelSize, height: pixelSize)
        let highlightPath = NSBezierPath(rect: highlight.insetBy(dx: 0.75, dy: 0.75))
        NSColor(white: 0, alpha: 0.5).setStroke(); highlightPath.lineWidth = 3; highlightPath.stroke()
        Brand.red.setStroke(); highlightPath.lineWidth = 1.5; highlightPath.stroke()

        // 테두리 (HUDSurfaceView와 동일)
        NSColor.white.withAlphaComponent(0.14).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        // 좌표/HEX 읽기
        let hex = String(format: "#%02X%02X%02X", lastColor.r, lastColor.g, lastColor.b)
        drawReadout(hex: hex, coordinates: "\(centerX), \(centerY)", below: frame, swatch: lastColor)
    }

    /// 루페 아래 판독 알약: ● HEX   X, Y
    private func drawReadout(hex: String, coordinates: String, below frame: CGRect,
                             swatch: (r: UInt8, g: UInt8, b: UInt8)) {
        let hexText = hex as NSString
        let coordText = coordinates as NSString
        let hexAttributes = overlayLabelAttributes(weight: .semibold)
        var coordAttributes = overlayLabelAttributes(weight: .medium)
        coordAttributes[.foregroundColor] = NSColor.white.withAlphaComponent(0.7)
        let hexSize = hexText.size(withAttributes: hexAttributes)
        let coordSize = coordText.size(withAttributes: coordAttributes)

        let swatchSide: CGFloat = 10
        let padX: CGFloat = 9, padY: CGFloat = 5, spacing: CGFloat = 8
        let pillSize = CGSize(width: padX * 2 + swatchSide + 6 + hexSize.width + spacing + coordSize.width,
                              height: padY * 2 + max(hexSize.height, swatchSide))
        let pill = CGRect(x: frame.minX, y: frame.maxY + 6, width: pillSize.width, height: pillSize.height)

        NSColor(white: 0, alpha: 0.78).setFill()
        NSBezierPath(roundedRect: pill, xRadius: Brand.innerCornerRadius, yRadius: Brand.innerCornerRadius).fill()

        var x = pill.minX + padX
        let swatchRect = CGRect(x: x, y: pill.midY - swatchSide / 2, width: swatchSide, height: swatchSide)
        NSColor(srgbRed: CGFloat(swatch.r) / 255, green: CGFloat(swatch.g) / 255,
                blue: CGFloat(swatch.b) / 255, alpha: 1).setFill()
        NSBezierPath(ovalIn: swatchRect).fill()
        NSColor.white.withAlphaComponent(0.5).setStroke()
        NSBezierPath(ovalIn: swatchRect).stroke()
        x += swatchSide + 6
        hexText.draw(at: CGPoint(x: x, y: pill.midY - hexSize.height / 2), withAttributes: hexAttributes)
        x += hexSize.width + spacing
        coordText.draw(at: CGPoint(x: x, y: pill.midY - coordSize.height / 2), withAttributes: coordAttributes)
    }

    private func drawDimensionLabel(for sel: CGRect) {
        let widthPx = Int((sel.width * scale).rounded())
        let heightPx = Int((sel.height * scale).rounded())
        let text = "\(widthPx) x \(heightPx)" as NSString
        let attributes = overlayLabelAttributes(weight: .semibold)
        let textSize = text.size(withAttributes: attributes)
        let padding: CGFloat = 5
        var pill = CGRect(x: sel.minX,
                          y: sel.minY - textSize.height - padding * 2 - 4,
                          width: textSize.width + padding * 2,
                          height: textSize.height + padding * 2)
        if pill.minY < 4 { pill.origin.y = sel.maxY + 4 }   // 위 공간 없으면 아래로

        let pillPath = NSBezierPath(roundedRect: pill, xRadius: Brand.innerCornerRadius, yRadius: Brand.innerCornerRadius)
        NSColor(white: 0, alpha: 0.75).setFill()
        pillPath.fill()
        text.draw(at: CGPoint(x: pill.minX + padding, y: pill.minY + padding), withAttributes: attributes)
    }

    // MARK: 안내 요소

    /// 호버 중인 창의 앱 이름과 구역(창 전체 / 본문)을 하이라이트 위에 이름표로 보여 준다.
    /// 실선·점선 차이만으로 두 구역을 구분하게 두면 "왜 이만큼만 잡히지?"가 생긴다.
    private func drawZoneLabel(for rect: CGRect, isFullWindow: Bool) {
        let clipped = rect.intersection(bounds)
        guard !clipped.isEmpty else { return }

        let zone = isFullWindow ? "창 전체" : "본문"
        let appName = hoveredWindow?.owningApplication?.applicationName ?? ""
        let text = (appName.isEmpty ? zone : "\(appName) · \(zone)") as NSString
        let attributes = overlayLabelAttributes(weight: .semibold, size: 11)
        let textSize = text.size(withAttributes: attributes)

        let icon = appIcon(for: hoveredWindow)
        let iconSide: CGFloat = icon == nil ? 0 : 14
        let iconGap: CGFloat = icon == nil ? 0 : 5
        let padX: CGFloat = 8, padY: CGFloat = 5
        let pillSize = CGSize(width: padX * 2 + iconSide + iconGap + textSize.width,
                              height: padY * 2 + max(textSize.height, iconSide))

        // 하이라이트 바로 위(디밍 영역)에 두고, 위 공간이 없으면 안쪽 좌상단으로.
        var origin = CGPoint(x: clipped.minX, y: clipped.minY - pillSize.height - 6)
        if origin.y < 4 { origin = CGPoint(x: clipped.minX + 8, y: clipped.minY + 8) }
        origin.x = max(4, min(origin.x, bounds.width - pillSize.width - 4))
        let pill = CGRect(origin: origin, size: pillSize)

        NSColor(white: 0, alpha: 0.78).setFill()
        NSBezierPath(roundedRect: pill, xRadius: Brand.innerCornerRadius, yRadius: Brand.innerCornerRadius).fill()

        var x = pill.minX + padX
        if let icon {
            let iconRect = CGRect(x: x, y: pill.midY - iconSide / 2, width: iconSide, height: iconSide)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iconSide + iconGap
        }
        text.draw(at: CGPoint(x: x, y: pill.midY - textSize.height / 2), withAttributes: attributes)
    }

    private func appIcon(for window: SCWindow?) -> NSImage? {
        guard let pid = window?.owningApplication?.processID else { return nil }
        if let cached = appIconCache[pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        appIconCache[pid] = icon
        return icon
    }

    /// 단계별 조작 안내. 단계가 바뀐 직후 잠깐 보이고 사라져 눈에 익은 사용자를 방해하지 않는다.
    private func drawHint() {
        let elapsed = Date().timeIntervalSince(hintShownAt)
        let alpha: CGFloat
        if elapsed < hintHold {
            alpha = 1
        } else if elapsed < hintHold + hintFade {
            alpha = CGFloat(1 - (elapsed - hintHold) / hintFade)
        } else {
            hintRect = .zero
            return
        }

        let text = (selectionLocked ? adjustingHint : idleHint) as NSString
        var attributes = overlayLabelAttributes(weight: .medium, size: 12)
        attributes[.foregroundColor] = NSColor.white.withAlphaComponent(alpha)
        let textSize = text.size(withAttributes: attributes)
        let padX: CGFloat = 14, padY: CGFloat = 8
        let pill = CGRect(x: (bounds.width - textSize.width) / 2 - padX,
                          y: 52,                               // 메뉴 막대 바로 아래
                          width: textSize.width + padX * 2,
                          height: textSize.height + padY * 2)
        hintRect = pill

        NSColor(white: 0, alpha: 0.72 * alpha).setFill()
        NSBezierPath(roundedRect: pill, xRadius: Brand.cornerRadius, yRadius: Brand.cornerRadius).fill()
        text.draw(at: CGPoint(x: pill.minX + padX, y: pill.minY + padY), withAttributes: attributes)
    }

    /// 앱의 다른 HUD와 같은 시스템 서체(숫자 고정폭)를 쓴다.
    /// `monospacedSystemFont`는 일부 macOS에서 CT 속성에 nil 폰트를 남겨 `draw` 중 abort 되므로 피한다.
    private func overlayLabelAttributes(weight: NSFont.Weight, size: CGFloat = 11) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white
        ]
    }
}
