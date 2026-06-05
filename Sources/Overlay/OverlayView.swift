import AppKit
import ScreenCaptureKit

/// 디밍 + 크로스헤어 + 라이브 확대경(루페) + 선택 사각형 + 윈도우 하이라이트를 그리는 뷰.
/// `isFlipped == true`라 좌상단 기준 point 좌표를 쓴다(픽셀 좌표와 동일 방향).
///
/// 인터랙션 분기:
/// - 호버(버튼 안 누름): 커서 아래 윈도우를 자동 감지해 하이라이트 → 클릭하면 윈도우 캡처
/// - 드래그(임계값 초과): 기존 영역 캡처 모드
final class OverlayView: NSView {
    // OverlayController가 주입
    var scale: CGFloat = 1
    var displayID: CGDirectDisplayID = 0
    var cgOrigin: CGPoint = .zero          // 이 디스플레이의 CG 전역 좌상단 원점(point)
    weak var provider: DisplayStreamProvider?
    weak var hitTester: WindowHitTester?
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onWindowCapture: ((SCWindow) -> Void)?

    private var cursor: CGPoint = .zero
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var cursorInside = false
    private var didDrag = false
    private let dragThreshold: CGFloat = 5

    // 호버 중 감지된 윈도우
    private var hoveredWindow: SCWindow?
    private var hoveredWindowRect: CGRect?     // 이 뷰의 로컬 좌표(좌상단 기준)

    // 루페 렌더 상태
    private let loupeRadius = 22                 // 한 변 45px 소스 영역
    private let loupeSize: CGFloat = 184
    private var loupeDirtyFrame: CGRect = .zero
    private var lastColor: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    // MARK: 트래킹
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        // 진입 이벤트에도 실제 위치를 반영해야 첫 mouseMoved 전 (0,0) 크로스헤어가 안 보인다.
        cursor = convert(event.locationInWindow, from: nil)
        cursorInside = true
        updateHoveredWindow()
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { cursorInside = false; needsDisplay = true }

    /// 오버레이가 막 떠서 아직 마우스 이벤트가 오기 전, 현재 커서 위치로 초기화한다.
    /// 커서가 이 디스플레이 위에 있을 때만 표시를 켠다(멀티 디스플레이 대응).
    func primeCursor() {
        guard let window else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(local) else { return }
        cursor = local
        cursorInside = true
        updateHoveredWindow()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        cursorInside = true
        updateHoveredWindow()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        cursor = point
        didDrag = false
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        if let start = dragStart {
            if hypot(point.x - start.x, point.y - start.y) >= dragThreshold { didDrag = true }
            selection = makeRect(start, point, square: event.modifierFlags.contains(.shift))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { dragStart = nil; didDrag = false }
        guard let start = dragStart else { return }

        if didDrag {
            // 드래그 → 영역 캡처
            let rect = makeRect(start, point, square: event.modifierFlags.contains(.shift))
            onFinish?(rect)
        } else if let window = hoveredWindow {
            // 클릭(드래그 없음) + 감지된 윈도우 → 윈도우 캡처
            onWindowCapture?(window)
        } else {
            onCancel?()
        }
    }

    private func updateHoveredWindow() {
        guard let hitTester else { hoveredWindow = nil; hoveredWindowRect = nil; return }
        let globalPoint = CGPoint(x: cgOrigin.x + cursor.x, y: cgOrigin.y + cursor.y)
        if let candidate = hitTester.window(at: globalPoint) {
            hoveredWindow = candidate.scWindow
            hoveredWindowRect = CGRect(x: candidate.cgFrame.minX - cgOrigin.x,
                                       y: candidate.cgFrame.minY - cgOrigin.y,
                                       width: candidate.cgFrame.width,
                                       height: candidate.cgFrame.height)
        } else {
            hoveredWindow = nil
            hoveredWindowRect = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }   // Esc
    }

    // 우클릭(또는 트랙패드 두 손가락 클릭)으로 언제든 취소. 키 입력이 오버레이로
    // 전달되지 않는 상황(앱이 key가 못 된 경우)에도 마우스 이벤트는 항상 도달하므로
    // 가장 확실한 취소 경로다.
    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    /// 타이머가 호출 — 커서가 멈춰 있어도 루페 픽셀을 갱신.
    func refreshLoupe() {
        guard cursorInside, loupeDirtyFrame != .zero else { return }
        setNeedsDisplay(loupeDirtyFrame)
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

    // MARK: 그리기
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 디밍 (dirtyRect로 클리핑되어 부분 갱신 시 저렴)
        NSColor(white: 0, alpha: 0.30).setFill()
        bounds.fill()

        let dragging = didDrag

        if dragging, let sel = selection, sel.width > 0, sel.height > 0 {
            ctx.clear(sel)                                   // 선택 영역은 투명하게 → 실제 화면이 비침
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: sel)
            border.lineWidth = 1
            border.stroke()
            drawDimensionLabel(for: sel)
        } else if let windowRect = hoveredWindowRect {
            drawWindowHighlight(windowRect, ctx)
        }

        guard cursorInside else { return }
        drawCrosshair()
        drawLoupe(ctx)
    }

    private func drawWindowHighlight(_ rect: CGRect, _ ctx: CGContext) {
        let clipped = rect.intersection(bounds)
        guard !clipped.isEmpty else { return }
        ctx.clear(clipped)                                   // 실제 윈도우가 비치도록 디밍 제거
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: clipped).fill()                   // 클릭 가능 표시(연한 강조색)
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: clipped.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()
    }

    private func drawCrosshair() {
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let vertical = NSBezierPath()
        vertical.move(to: CGPoint(x: cursor.x, y: 0))
        vertical.line(to: CGPoint(x: cursor.x, y: bounds.height))
        let horizontal = NSBezierPath()
        horizontal.move(to: CGPoint(x: 0, y: cursor.y))
        horizontal.line(to: CGPoint(x: bounds.width, y: cursor.y))
        vertical.lineWidth = 1
        horizontal.lineWidth = 1
        vertical.stroke()
        horizontal.stroke()
    }

    private func drawLoupe(_ ctx: CGContext) {
        let textHeight: CGFloat = 38
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
        let bg = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        NSColor(white: 0.12, alpha: 0.92).setFill()
        bg.fill()

        // 라이브 픽셀
        let centerX = Int((cursor.x * scale).rounded())
        let centerY = Int((cursor.y * scale).rounded())
        if let buffer = provider?.latestBuffer(),
           let region = PixelSampling.sample(buffer, centerX: centerX, centerY: centerY, radius: loupeRadius) {
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

        // 중앙 픽셀 하이라이트
        let highlight = CGRect(x: cx - pixelSize / 2, y: cy - pixelSize / 2,
                               width: pixelSize, height: pixelSize)
        NSColor.white.setStroke()
        let highlightPath = NSBezierPath(rect: highlight)
        highlightPath.lineWidth = 1
        highlightPath.stroke()

        // 테두리
        NSColor.white.withAlphaComponent(0.5).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        // 좌표/HEX 읽기
        let hex = String(format: "#%02X%02X%02X", lastColor.r, lastColor.g, lastColor.b)
        let info = "X \(centerX)  Y \(centerY)\n\(hex)"
        drawReadout(info, below: frame, swatch: lastColor)
    }

    private func drawReadout(_ text: String, below frame: CGRect, swatch: (r: UInt8, g: UInt8, b: UInt8)) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textOrigin = CGPoint(x: frame.minX + 18, y: frame.maxY + 6)
        (text as NSString).draw(at: textOrigin, withAttributes: attributes)

        // 색상 스와치
        let swatchRect = CGRect(x: frame.minX, y: frame.maxY + 8, width: 12, height: 12)
        NSColor(srgbRed: CGFloat(swatch.r) / 255, green: CGFloat(swatch.g) / 255,
                blue: CGFloat(swatch.b) / 255, alpha: 1).setFill()
        NSBezierPath(rect: swatchRect).fill()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        NSBezierPath(rect: swatchRect).stroke()
    }

    private func drawDimensionLabel(for sel: CGRect) {
        let widthPx = Int((sel.width * scale).rounded())
        let heightPx = Int((sel.height * scale).rounded())
        let text = "\(widthPx) × \(heightPx)" as NSString

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding: CGFloat = 5
        var pill = CGRect(x: sel.minX,
                          y: sel.minY - textSize.height - padding * 2 - 4,
                          width: textSize.width + padding * 2,
                          height: textSize.height + padding * 2)
        if pill.minY < 4 { pill.origin.y = sel.maxY + 4 }   // 위 공간 없으면 아래로

        let pillPath = NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4)
        NSColor(white: 0, alpha: 0.75).setFill()
        pillPath.fill()
        text.draw(at: CGPoint(x: pill.minX + padding, y: pill.minY + padding), withAttributes: attributes)
    }
}
