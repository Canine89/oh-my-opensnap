import AppKit

/// 라이브러리 미리보기 겸 간단 편집 뷰.
/// 도구: 크롭(핸들 방식) / 번호(➊–➒) / 화살표 / 사각형 / 원. 좌상단 원점(isFlipped).
/// 좌표는 이미지 픽셀과 1:1 (캡처 PNG는 72dpi라 size(point) == 픽셀).
/// ⌘Z 되돌리기는 스냅샷 스택으로 크롭 포함 모든 편집에 적용된다.
final class EditorImageView: NSView {

    enum Tool { case none, crop, number, arrow, rectangle, ellipse }

    struct Annotation {
        enum Kind { case number(Int), arrow, rectangle, ellipse }
        let kind: Kind
        let start: CGPoint
        let end: CGPoint
        let color: NSColor
        let width: CGFloat
    }

    private enum Handle { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, center }

    private struct Snapshot {
        let image: NSImage?
        let annotations: [Annotation]
        let nextNumber: Int
    }

    // MARK: 공개 상태
    var tool: Tool = .none {
        didSet {
            cropRect = (tool == .crop) ? bounds : nil
            activeHandle = nil
            // 번호 도구로 바꾸면 현재 커서 위치에서 스탬프 미리보기를 즉시 띄운다.
            if tool == .number, let window {
                let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                hoverPoint = bounds.contains(point) ? point : nil
            } else {
                hoverPoint = nil
            }
            notifyCropProgress()
            needsDisplay = true
        }
    }
    var strokeColor: NSColor = Brand.red
    var strokeWidth: CGFloat = 3
    var onImageChanged: (() -> Void)?
    /// 크롭이 조금이라도 진행됐는지(전체 영역과 달라졌는지) 알림 → [완료] 버튼 표시용.
    var onCropProgress: ((Bool) -> Void)?
    /// 클립보드 복사 성공 시 호출 (경로 무관) → 토스트 표시용.
    var onDidCopy: (() -> Void)?
    /// 이미지 자체가 바뀌는 편집(크롭 적용 / 크롭 되돌리기)이 일어났을 때 호출.
    /// → 라이브러리 파일을 현재 상태로 다시 저장해 디스크와 화면을 일치시키는 데 쓴다.
    /// (주석만 추가/제거되는 편집은 기존처럼 원본을 건드리지 않으므로 발생시키지 않는다.)
    var onEditCommitted: (() -> Void)?

    /// 새 이미지 로드 (편집/undo 전부 초기화).
    var image: NSImage? {
        get { backingImage }
        set { load(newValue) }
    }

    // MARK: 내부 상태
    private var backingImage: NSImage?
    private var annotations: [Annotation] = []
    private var nextNumber = 1
    private var undoStack: [Snapshot] = []

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    /// 번호 도구에서 커서를 따라다니는 스탬프 미리보기 위치(뷰 좌표). nil이면 표시 안 함.
    private var hoverPoint: CGPoint?
    private var trackingArea: NSTrackingArea?

    private var cropRect: CGRect?
    private var activeHandle: Handle?
    private var dragOrigin: CGPoint = .zero
    private var cropStartRect: CGRect = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var zoomScale: CGFloat { enclosingScrollView?.magnification ?? 1 }

    // MARK: 이미지 로드/교체
    private func load(_ image: NSImage?) {
        backingImage = image
        annotations.removeAll()
        nextNumber = 1
        undoStack.removeAll()
        cropRect = (tool == .crop) ? CGRect(origin: .zero, size: image?.size ?? .zero) : nil
        if let size = image?.size { setFrameSize(size) }
        onImageChanged?()
        notifyCropProgress()
        needsDisplay = true
    }

    private func replaceImage(_ image: NSImage?, annotations: [Annotation], nextNumber: Int) {
        backingImage = image
        self.annotations = annotations
        self.nextNumber = nextNumber
        cropRect = (tool == .crop) ? CGRect(origin: .zero, size: image?.size ?? .zero) : nil
        if let size = image?.size { setFrameSize(size) }
        onImageChanged?()
        notifyCropProgress()
        needsDisplay = true
    }

    private func notifyCropProgress() {
        guard tool == .crop, let rect = cropRect else { onCropProgress?(false); return }
        let full = bounds
        let progressed = abs(rect.minX - full.minX) > 0.5 || abs(rect.minY - full.minY) > 0.5
            || abs(rect.maxX - full.maxX) > 0.5 || abs(rect.maxY - full.maxY) > 0.5
        onCropProgress?(progressed)
    }

    /// [완료] 버튼에서 호출 — 크롭 적용.
    func commitCrop() {
        applyCrop()
    }

    // MARK: Undo
    private func pushUndo() {
        undoStack.append(Snapshot(image: backingImage, annotations: annotations, nextNumber: nextNumber))
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        // 이미지 인스턴스가 달라지면(=크롭 적용/해제) 디스크 파일도 되돌려야 한다.
        let imageChanged = snapshot.image !== backingImage
        replaceImage(snapshot.image, annotations: snapshot.annotations, nextNumber: snapshot.nextNumber)
        if imageChanged { onEditCommitted?() }
    }

    // MARK: 마우스
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = clamp(convert(event.locationInWindow, from: nil))
        switch tool {
        case .number:
            pushUndo()
            annotations.append(Annotation(kind: .number(nextNumber), start: point, end: point,
                                          color: strokeColor, width: strokeWidth))
            nextNumber = nextNumber >= 9 ? 1 : nextNumber + 1
            hoverPoint = nil    // 방금 찍은 자리와 겹치지 않게; 커서를 움직이면 다음 번호 미리보기가 다시 뜬다
            needsDisplay = true
        case .crop:
            if event.clickCount == 2, (cropRect ?? .zero).contains(point) { applyCrop(); return }
            activeHandle = handle(at: point) ?? ((cropRect ?? .zero).contains(point) ? .center : nil)
            dragOrigin = point
            cropStartRect = cropRect ?? bounds
        case .arrow, .rectangle, .ellipse:
            dragStart = point
            dragCurrent = point
        case .none:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamp(convert(event.locationInWindow, from: nil))
        switch tool {
        case .crop:
            guard let handle = activeHandle else { return }
            cropRect = adjustedCropRect(handle: handle, point: point)
            notifyCropProgress()
            needsDisplay = true
        case .arrow, .rectangle, .ellipse:
            guard let start = dragStart else { return }
            // Shift: 사각형/원은 1:1, 화살표는 45° 단위로 반듯하게.
            dragCurrent = event.modifierFlags.contains(.shift) ? constrained(from: start, to: point) : point
            needsDisplay = true
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch tool {
        case .crop:
            activeHandle = nil
        case .arrow, .rectangle, .ellipse:
            defer { dragStart = nil; dragCurrent = nil }
            guard let start = dragStart else { return }
            let raw = clamp(convert(event.locationInWindow, from: nil))
            let end = event.modifierFlags.contains(.shift) ? constrained(from: start, to: raw) : raw
            guard hypot(end.x - start.x, end.y - start.y) > 2 else { return }
            let kind: Annotation.Kind = tool == .arrow ? .arrow : (tool == .rectangle ? .rectangle : .ellipse)
            pushUndo()
            annotations.append(Annotation(kind: kind, start: start, end: end,
                                          color: strokeColor, width: strokeWidth))
            needsDisplay = true
        default:
            break
        }
    }

    // MARK: 커서 추적 (번호 스탬프 미리보기)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard tool == .number else { return }
        hoverPoint = clamp(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        guard tool == .number else { return }
        hoverPoint = clamp(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoverPoint != nil else { return }
        hoverPoint = nil
        needsDisplay = true
    }

    // MARK: 키보드
    // ⌘ 조합은 keyDown보다 먼저 performKeyEquivalent로 전달되므로 여기서 처리한다.
    // (first responder가 색상 well/슬라이더에 있어도 창이 떠 있으면 동작)
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let scroll = enclosingScrollView as? ZoomableScrollView
        switch event.charactersIgnoringModifiers {
        case "z": undo(); return true
        case "c": copyToClipboard(); return true
        case "=", "+": scroll?.zoomBy(1.25); return true
        case "-", "_": scroll?.zoomBy(0.8); return true
        case "0": scroll?.zoomToFit(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: applyCrop()        // Return / Enter
        case 53: tool = .none           // Esc → 크롭 취소
        default: super.keyDown(with: event)
        }
    }

    // 표준 Edit 메뉴(⌘Z/⌘C) 라우팅용 responder 액션
    @objc func undo(_ sender: Any?) { undo() }
    @objc func copy(_ sender: Any?) { copyToClipboard() }

    // MARK: 크롭
    private func applyCrop() {
        guard tool == .crop, let rect = cropRect, let cg = renderedCGImage() else { return }
        let pxRect = rect.integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !pxRect.isEmpty, let cropped = cg.cropping(to: pxRect) else { return }
        pushUndo()
        replaceImage(NSImage(cgImage: cropped, size: pxRect.size), annotations: [], nextNumber: 1)
        onEditCommitted?()      // 크롭 결과를 라이브러리 파일에 반영
    }

    private func handlePoints(_ rect: CGRect) -> [(Handle, CGPoint)] {
        [(.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
         (.top, CGPoint(x: rect.midX, y: rect.minY)),
         (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
         (.right, CGPoint(x: rect.maxX, y: rect.midY)),
         (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
         (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
         (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
         (.left, CGPoint(x: rect.minX, y: rect.midY)),
         (.center, CGPoint(x: rect.midX, y: rect.midY))]
    }

    private func handle(at point: CGPoint) -> Handle? {
        guard let rect = cropRect else { return nil }
        let radius = 20 / zoomScale     // 화면상 약 20pt — 너그러운 클릭 판정
        // 가장 가까운 핸들을 고른다(반경 내에서). 모서리/변 우선, center 제외.
        var best: (handle: Handle, distance: CGFloat)?
        for (handle, position) in handlePoints(rect) where handle != .center {
            let distance = hypot(point.x - position.x, point.y - position.y)
            if distance <= radius, best == nil || distance < best!.distance {
                best = (handle, distance)
            }
        }
        return best?.handle
    }

    private func adjustedCropRect(handle: Handle, point: CGPoint) -> CGRect {
        let minSize: CGFloat = 12
        if handle == .center {
            let dx = point.x - dragOrigin.x
            let dy = point.y - dragOrigin.y
            var origin = CGPoint(x: cropStartRect.minX + dx, y: cropStartRect.minY + dy)
            origin.x = min(max(0, origin.x), bounds.width - cropStartRect.width)
            origin.y = min(max(0, origin.y), bounds.height - cropStartRect.height)
            return CGRect(origin: origin, size: cropStartRect.size)
        }
        var minX = cropStartRect.minX, minY = cropStartRect.minY
        var maxX = cropStartRect.maxX, maxY = cropStartRect.maxY
        if [.topLeft, .left, .bottomLeft].contains(handle) { minX = min(point.x, maxX - minSize) }
        if [.topRight, .right, .bottomRight].contains(handle) { maxX = max(point.x, minX + minSize) }
        if [.topLeft, .top, .topRight].contains(handle) { minY = min(point.y, maxY - minSize) }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { maxY = max(point.y, minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: 클립보드
    func copyToClipboard() {
        guard let cg = renderedCGImage() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(png, forType: NSPasteboard.PasteboardType("com.apple.pboard.type.PNGf"))
        onDidCopy?()
    }

    // MARK: 렌더 (이미지 + 주석 합성, 픽셀 정확)
    func renderedCGImage() -> CGImage? {
        guard let image = backingImage else { return nil }
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // 화면의 flipped 뷰와 동일하게: CTM을 좌상단 원점으로 뒤집고 isFlipped=true 컨텍스트 사용.
        // (이 둘을 같이 맞춰야 이미지가 똑바로 그려진다.)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        image.draw(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        for annotation in annotations { draw(annotation) }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: 그리기
    override func draw(_ dirtyRect: NSRect) {
        backingImage?.draw(in: bounds)
        for annotation in annotations { draw(annotation) }

        if tool != .crop, let start = dragStart, let current = dragCurrent {
            switch tool {
            case .arrow:
                draw(Annotation(kind: .arrow, start: start, end: current, color: strokeColor, width: strokeWidth))
            case .rectangle:
                draw(Annotation(kind: .rectangle, start: start, end: current, color: strokeColor, width: strokeWidth))
            case .ellipse:
                draw(Annotation(kind: .ellipse, start: start, end: current, color: strokeColor, width: strokeWidth))
            default:
                break
            }
        }

        // 번호 도구: 커서를 따라다니는 반투명 스탬프 미리보기(다음에 찍힐 번호)
        if tool == .number, let hoverPoint {
            drawNumber(nextNumber, at: hoverPoint, color: strokeColor, width: strokeWidth, alpha: 0.55)
        }

        if tool == .crop, let rect = cropRect { drawCropOverlay(rect) }
    }

    private func draw(_ annotation: Annotation) {
        annotation.color.setStroke()
        annotation.color.setFill()
        switch annotation.kind {
        case .number(let value):
            drawNumber(value, at: annotation.start, color: annotation.color, width: annotation.width)
        case .arrow:
            drawArrow(from: annotation.start, to: annotation.end, width: annotation.width)
        case .rectangle:
            let path = NSBezierPath(rect: Self.rect(annotation.start, annotation.end))
            path.lineWidth = annotation.width
            path.stroke()
        case .ellipse:
            let path = NSBezierPath(ovalIn: Self.rect(annotation.start, annotation.end))
            path.lineWidth = annotation.width
            path.stroke()
        }
    }

    /// 동글 번호 하나를 그린다. `alpha < 1`이면 커서를 따라다니는 스탬프 미리보기 용도.
    private func drawNumber(_ value: Int, at center: CGPoint, color: NSColor, width: CGFloat, alpha: CGFloat = 1) {
        let radius = max(12, width * 3.5)
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
        let text = "\(value)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: radius * 1.15),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha)
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                  withAttributes: attributes)
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, width: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(12, width * 3.5)
        let shaftEnd = CGPoint(x: end.x - cos(angle) * headLength * 0.7,
                               y: end.y - sin(angle) * headLength * 0.7)
        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.line(to: shaftEnd)
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        shaft.stroke()

        let left = CGPoint(x: end.x - cos(angle - .pi / 7) * headLength,
                           y: end.y - sin(angle - .pi / 7) * headLength)
        let right = CGPoint(x: end.x - cos(angle + .pi / 7) * headLength,
                            y: end.y - sin(angle + .pi / 7) * headLength)
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: left)
        head.line(to: right)
        head.close()
        head.fill()
    }

    private func drawCropOverlay(_ rect: CGRect) {
        // 바깥 어둡게
        let mask = NSBezierPath(rect: bounds)
        mask.append(NSBezierPath(rect: rect))
        mask.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.5).setFill()
        mask.fill()

        // 테두리
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1 / zoomScale
        NSColor.white.setStroke()
        border.stroke()

        // 9개 선택점
        let handleSize = 12 / zoomScale
        for (_, position) in handlePoints(rect) {
            let dot = CGRect(x: position.x - handleSize / 2, y: position.y - handleSize / 2,
                             width: handleSize, height: handleSize)
            NSColor.white.setFill()
            NSBezierPath(rect: dot).fill()
            NSColor(white: 0, alpha: 0.6).setStroke()
            let outline = NSBezierPath(rect: dot)
            outline.lineWidth = 1 / zoomScale
            outline.stroke()
        }
    }

    // MARK: 유틸
    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
    }

    /// Shift 제약을 적용한 끝점.
    /// - 사각형/원: 시작점에서 가로·세로 변 길이를 같게(1:1) 맞춘다.
    /// - 화살표: 시작점 기준 각도를 45° 단위로 스냅해 수평/수직/대각선으로 반듯하게.
    private func constrained(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        switch tool {
        case .rectangle, .ellipse:
            let side = max(abs(dx), abs(dy))
            return clamp(CGPoint(x: start.x + (dx < 0 ? -side : side),
                                 y: start.y + (dy < 0 ? -side : side)))
        case .arrow:
            let length = hypot(dx, dy)
            let snapped = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            return clamp(CGPoint(x: start.x + cos(snapped) * length,
                                 y: start.y + sin(snapped) * length))
        default:
            return end
        }
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
