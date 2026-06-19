import AppKit

/// 라이브러리 미리보기 겸 간단 편집 뷰.
/// 도구: 크롭(핸들 방식) / 번호(➊–➒) / 텍스트 / 말풍선 / 화살표 / 사각형 / 원. 좌상단 원점(isFlipped).
/// 좌표는 이미지 픽셀과 1:1 (캡처 PNG는 72dpi라 size(point) == 픽셀).
/// ⌘Z 되돌리기는 스냅샷 스택으로 크롭 포함 모든 편집에 적용된다.
final class EditorImageView: NSView {

    enum Tool { case none, crop, number, text, callout, arrow, rectangle, ellipse, mosaic }

    struct Annotation {
        enum Kind { case number(Int), text(String), callout(String), arrow, rectangle, ellipse, mosaic }
        var kind: Kind
        var start: CGPoint
        var end: CGPoint
        let color: NSColor
        let width: CGFloat
        /// 모자이크 전용: 영역을 다운샘플한 작은 이미지(그릴 때 보간 없이 확대 → 블록).
        var mosaicImage: CGImage? = nil
    }

    private enum Handle { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, center }

    private struct PendingTextAnnotation {
        enum Kind { case text, callout }
        let kind: Kind
        let start: CGPoint
        let end: CGPoint
        let color: NSColor
        let width: CGFloat
        let editingIndex: Int?
        let initialText: String

        init(kind: Kind, start: CGPoint, end: CGPoint, color: NSColor, width: CGFloat,
             editingIndex: Int? = nil, initialText: String = "") {
            self.kind = kind
            self.start = start
            self.end = end
            self.color = color
            self.width = width
            self.editingIndex = editingIndex
            self.initialText = initialText
        }
    }

    private struct AnnotationDrag {
        enum Kind: Equatable { case text, calloutBubble, calloutHead }
        let kind: Kind
        let index: Int
        let origin: CGPoint
        let initialStart: CGPoint
        let initialEnd: CGPoint
        var didMove = false
        var didPushUndo = false
    }

    private struct Snapshot {
        let image: NSImage?
        let annotations: [Annotation]
        let nextNumber: Int
        let cropRect: CGRect?      // 크롭 범위도 되돌림 대상
    }

    // MARK: 공개 상태
    var tool: Tool = .none {
        didSet {
            if activeTextField != nil { commitActiveTextField() }
            cropRect = (tool == .crop) ? bounds : nil
            activeHandle = nil
            dragStart = nil
            dragCurrent = nil
            annotationDrag = nil
            cropLoupePoint = nil
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
    private var backingImage: NSImage? { didSet { backingCG = nil } }
    /// 모자이크 샘플링용 backingImage의 CGImage 캐시.
    private var backingCG: CGImage?
    private var annotations: [Annotation] = []
    private var nextNumber = 1
    private var undoStack: [Snapshot] = []

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var activeTextField: InlineTextField?
    private var pendingTextAnnotation: PendingTextAnnotation?
    private var annotationDrag: AnnotationDrag?

    /// 번호 도구에서 커서를 따라다니는 스탬프 미리보기 위치(뷰 좌표). nil이면 표시 안 함.
    private var hoverPoint: CGPoint?
    private var trackingArea: NSTrackingArea?

    private var cropRect: CGRect?
    private var activeHandle: Handle?
    private var dragOrigin: CGPoint = .zero
    private var cropStartRect: CGRect = .zero
    /// 크롭 핸들을 드래그하는 동안 확대경을 띄울 지점(이미지 좌표). nil이면 표시 안 함.
    private var cropLoupePoint: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// 크롭 중에는 이미지 바깥 여백을 클릭해도 핸들을 잡을 수 있도록,
    /// 클립뷰가 여백 클릭 이벤트를 이 뷰로 넘겨준다. (핸들이 뷰 경계에 걸려 안 눌리던 문제 해결)
    var wantsMarginClicks: Bool { tool == .crop }

    private var zoomScale: CGFloat { enclosingScrollView?.magnification ?? 1 }

    // MARK: 이미지 로드/교체
    private func load(_ image: NSImage?) {
        cancelActiveTextField()
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
        undoStack.append(Snapshot(image: backingImage, annotations: annotations,
                                  nextNumber: nextNumber, cropRect: cropRect))
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    /// 명시한 크롭 범위로 되돌아가는 스냅샷을 쌓는다(크롭 핸들 드래그 직전 상태 보존용).
    private func pushCropSnapshot(_ rect: CGRect) {
        undoStack.append(Snapshot(image: backingImage, annotations: annotations,
                                  nextNumber: nextNumber, cropRect: rect))
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        // 이미지 인스턴스가 달라지면(=크롭 적용/해제) 디스크 파일도 되돌려야 한다.
        let imageChanged = snapshot.image !== backingImage
        backingImage = snapshot.image
        annotations = snapshot.annotations
        nextNumber = snapshot.nextNumber
        cropRect = snapshot.cropRect      // 크롭 범위 조정도 되돌린다
        activeHandle = nil
        annotationDrag = nil
        cropLoupePoint = nil
        if imageChanged {
            if let size = snapshot.image?.size { setFrameSize(size) }
            onImageChanged?()             // 이미지 자체가 바뀐 경우만 맞춤/포커스 갱신
            onEditCommitted?()            // 디스크 파일도 되돌림
        }
        notifyCropProgress()
        needsDisplay = true
    }

    // MARK: 마우스
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if activeTextField != nil {
            commitActiveTextField()
        }
        let point = clamp(convert(event.locationInWindow, from: nil))
        if tool != .crop, beginAnnotationDrag(at: point, allowedKinds: [.text, .calloutHead, .calloutBubble]) {
            return
        }
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
            // 변/모서리 핸들을 잡으면 그 지점에 확대경을 띄운다(가운데 이동은 제외).
            cropLoupePoint = (activeHandle != nil && activeHandle != .center) ? point : nil
            needsDisplay = true
        case .text:
            showTextEditor(for: PendingTextAnnotation(kind: .text, start: point, end: point,
                                                      color: strokeColor, width: strokeWidth))
        case .callout:
            dragStart = point
            dragCurrent = point
            needsDisplay = true
        case .arrow, .rectangle, .ellipse, .mosaic:
            dragStart = point
            dragCurrent = point
        case .none:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamp(convert(event.locationInWindow, from: nil))
        if updateAnnotationDrag(to: point) { return }
        switch tool {
        case .crop:
            guard let handle = activeHandle else { return }
            cropRect = adjustedCropRect(handle: handle, point: point)
            cropLoupePoint = (handle != .center) ? point : nil
            notifyCropProgress()
            needsDisplay = true
        case .arrow, .rectangle, .ellipse, .callout:
            guard let start = dragStart else { return }
            // Shift: 사각형/원은 1:1, 화살표는 45° 단위로 반듯하게. 말풍선은 자유 배치.
            dragCurrent = (tool != .callout && event.modifierFlags.contains(.shift)) ? constrained(from: start, to: point) : point
            needsDisplay = true
        case .mosaic:
            guard dragStart != nil else { return }
            dragCurrent = point
            needsDisplay = true
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if finishAnnotationDrag() { return }
        switch tool {
        case .crop:
            activeHandle = nil
            cropLoupePoint = nil
            // 범위가 실제로 바뀌었으면 드래그 직전 상태를 기록 → Cmd+Z로 범위 되돌리기
            if let cr = cropRect, cr != cropStartRect { pushCropSnapshot(cropStartRect) }
            needsDisplay = true
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
        case .callout:
            defer { dragStart = nil; dragCurrent = nil }
            guard let start = dragStart else { return }
            let end = clamp(convert(event.locationInWindow, from: nil))
            guard hypot(end.x - start.x, end.y - start.y) > 8 else { return }
            showTextEditor(for: PendingTextAnnotation(kind: .callout, start: start, end: end,
                                                      color: strokeColor, width: strokeWidth))
        case .mosaic:
            defer { dragStart = nil; dragCurrent = nil }
            guard let start = dragStart else { return }
            let end = clamp(convert(event.locationInWindow, from: nil))
            let rect = Self.rect(start, end)
            guard rect.width > 4, rect.height > 4, let small = makeMosaicSmall(rect: rect) else { return }
            pushUndo()
            annotations.append(Annotation(kind: .mosaic, start: start, end: end,
                                          color: .clear, width: 0, mosaicImage: small))
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
        case 53 where activeTextField != nil:
            cancelActiveTextField()
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

    // MARK: 주석 이동
    private func beginAnnotationDrag(at point: CGPoint, allowedKinds: [AnnotationDrag.Kind]) -> Bool {
        guard let hit = hitAnnotation(at: point), allowedKinds.contains(hit.kind) else { return false }
        let annotation = annotations[hit.index]
        annotationDrag = AnnotationDrag(kind: hit.kind, index: hit.index, origin: point,
                                        initialStart: annotation.start, initialEnd: annotation.end)
        return true
    }

    private func updateAnnotationDrag(to point: CGPoint) -> Bool {
        guard var drag = annotationDrag, annotations.indices.contains(drag.index) else { return false }
        let dx = point.x - drag.origin.x
        let dy = point.y - drag.origin.y
        guard drag.didMove || hypot(dx, dy) > max(2, 3 / zoomScale) else { return true }
        if !drag.didPushUndo {
            pushUndo()
            drag.didPushUndo = true
        }
        drag.didMove = true
        switch drag.kind {
        case .text:
            let start = clamp(CGPoint(x: drag.initialStart.x + dx, y: drag.initialStart.y + dy))
            annotations[drag.index].start = start
            annotations[drag.index].end = start
        case .calloutBubble:
            annotations[drag.index].end = clamp(CGPoint(x: drag.initialEnd.x + dx, y: drag.initialEnd.y + dy))
        case .calloutHead:
            annotations[drag.index].start = point
        }
        annotationDrag = drag
        needsDisplay = true
        return true
    }

    private func finishAnnotationDrag() -> Bool {
        guard let drag = annotationDrag else { return false }
        annotationDrag = nil
        if !drag.didMove {
            beginEditingAnnotation(at: drag.index, dragKind: drag.kind)
        }
        needsDisplay = true
        return true
    }

    private func beginEditingAnnotation(at index: Int, dragKind: AnnotationDrag.Kind) {
        guard annotations.indices.contains(index), dragKind != .calloutHead else { return }
        let annotation = annotations[index]
        switch annotation.kind {
        case .text(let value):
            showTextEditor(for: PendingTextAnnotation(kind: .text, start: annotation.start, end: annotation.end,
                                                      color: annotation.color, width: annotation.width,
                                                      editingIndex: index, initialText: value))
        case .callout(let value):
            showTextEditor(for: PendingTextAnnotation(kind: .callout, start: annotation.start, end: annotation.end,
                                                      color: annotation.color, width: annotation.width,
                                                      editingIndex: index, initialText: value))
        default:
            break
        }
    }

    private func hitAnnotation(at point: CGPoint) -> (index: Int, kind: AnnotationDrag.Kind)? {
        let hitInset = max(6, 8 / zoomScale)
        for index in annotations.indices.reversed() {
            let annotation = annotations[index]
            switch annotation.kind {
            case .text(let value):
                if textRect(value, at: annotation.start, width: annotation.width).insetBy(dx: -hitInset, dy: -hitInset).contains(point) {
                    return (index, .text)
                }
            case .callout(let value):
                let headRadius = max(10 / zoomScale, annotation.width * 4)
                if hypot(point.x - annotation.start.x, point.y - annotation.start.y) <= headRadius {
                    return (index, .calloutHead)
                }
                if calloutTextRect(text: value, anchor: annotation.end, width: annotation.width)
                    .insetBy(dx: -hitInset, dy: -hitInset)
                    .contains(point) {
                    return (index, .calloutBubble)
                }
            default:
                continue
            }
        }
        return nil
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
        if activeTextField != nil { commitActiveTextField() }
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
        for (index, annotation) in annotations.enumerated() where index != pendingTextAnnotation?.editingIndex {
            draw(annotation)
        }

        if let pending = pendingTextAnnotation, pending.kind == .callout, let field = activeTextField {
            drawCallout(text: field.stringValue, head: pending.start, bubbleAnchor: pending.end,
                        color: pending.color, width: pending.width, drawsText: false)
        }

        if tool != .crop, let start = dragStart, let current = dragCurrent {
            switch tool {
            case .callout:
                drawCallout(text: "", head: start, bubbleAnchor: current,
                            color: strokeColor, width: strokeWidth, alpha: 0.55)
            case .arrow:
                draw(Annotation(kind: .arrow, start: start, end: current, color: strokeColor, width: strokeWidth))
            case .rectangle:
                draw(Annotation(kind: .rectangle, start: start, end: current, color: strokeColor, width: strokeWidth))
            case .ellipse:
                draw(Annotation(kind: .ellipse, start: start, end: current, color: strokeColor, width: strokeWidth))
            case .mosaic:
                // 드래그 중 실시간 미리보기
                let rect = Self.rect(start, current)
                if let small = makeMosaicSmall(rect: rect) { drawMosaic(rect: rect, small: small) }
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let border = NSBezierPath(rect: rect)
                border.lineWidth = 1 / zoomScale
                border.stroke()
            default:
                break
            }
        }

        // 번호 도구: 커서를 따라다니는 반투명 스탬프 미리보기(다음에 찍힐 번호)
        if tool == .number, let hoverPoint {
            drawNumber(nextNumber, at: hoverPoint, color: strokeColor, width: strokeWidth, alpha: 0.55)
        }

        if tool == .crop, let rect = cropRect { drawCropOverlay(rect) }

        // 크롭 핸들 드래그 중: 커서 주변을 확대해 보여주는 루페(정밀 조정 보조)
        if tool == .crop, let point = cropLoupePoint {
            drawCropLoupe(around: point)
        }
    }

    /// 크롭 중 커서(핸들) 주변 픽셀을 확대해 보여주는 루페.
    /// 스크롤 배율(m)과 무관하게 화면상 일정 크기로 보이도록 1/m 로 보정해 그린다.
    private func drawCropLoupe(around p: CGPoint) {
        guard let image = backingImage else { return }
        let m = max(zoomScale, 0.0001)
        let screenDiameter: CGFloat = 150     // 화면상 루페 지름
        let pixelZoom: CGFloat = 6            // 화면상 이미지 확대율
        let d = screenDiameter / m            // 이미지 좌표계 지름
        let gap = 28 / m

        // 커서 우상단(flipped: y 작을수록 위)에 띄우되, 가장자리면 반대편으로 + 안쪽으로 클램프
        var c = CGPoint(x: p.x + gap + d / 2, y: p.y - gap - d / 2)
        if c.x + d / 2 > bounds.maxX { c.x = p.x - gap - d / 2 }
        if c.y - d / 2 < bounds.minY { c.y = p.y + gap + d / 2 }
        c.x = min(max(c.x, bounds.minX + d / 2), bounds.maxX - d / 2)
        c.y = min(max(c.y, bounds.minY + d / 2), bounds.maxY - d / 2)
        let loupe = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: loupe).addClip()
        NSColor(white: 0.12, alpha: 1).setFill()
        loupe.fill()
        // 이미지점 p가 루페 중심에 오도록 확대(화면 확대율 = scale*m = pixelZoom)
        let scale = pixelZoom / m
        let t = NSAffineTransform()
        t.translateX(by: c.x, yBy: c.y)
        t.scaleX(by: scale, yBy: scale)
        t.translateX(by: -p.x, yBy: -p.y)
        t.concat()
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        // 중앙 십자선(= 잘릴 경계) + 테두리
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: loupe.minX, y: c.y)); cross.line(to: CGPoint(x: loupe.maxX, y: c.y))
        cross.move(to: CGPoint(x: c.x, y: loupe.minY)); cross.line(to: CGPoint(x: c.x, y: loupe.maxY))
        cross.lineWidth = 1 / m
        cross.stroke()
        let border = NSBezierPath(ovalIn: loupe)
        border.lineWidth = 2 / m
        NSColor.white.withAlphaComponent(0.85).setStroke()
        border.stroke()
    }

    private func draw(_ annotation: Annotation) {
        annotation.color.setStroke()
        annotation.color.setFill()
        switch annotation.kind {
        case .number(let value):
            drawNumber(value, at: annotation.start, color: annotation.color, width: annotation.width)
        case .text(let value):
            drawText(value, at: annotation.start, color: annotation.color, width: annotation.width)
        case .callout(let value):
            drawCallout(text: value, head: annotation.start, bubbleAnchor: annotation.end,
                        color: annotation.color, width: annotation.width)
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
        case .mosaic:
            if let small = annotation.mosaicImage {
                drawMosaic(rect: Self.rect(annotation.start, annotation.end), small: small)
            }
        }
    }

    /// 작은(다운샘플) 이미지를 보간 없이 영역에 확대해 그린다 → 블록 모자이크.
    private func drawMosaic(rect: CGRect, small: CGImage) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: small, size: rect.size).draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 영역을 블록 격자 수만큼 다운샘플한 작은 CGImage를 만든다(블록당 평균색).
    private func makeMosaicSmall(rect: CGRect) -> CGImage? {
        guard let cg = backingImageCG() else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let r = rect.integral.intersection(imageBounds)
        guard r.width >= 2, r.height >= 2, let cropped = cg.cropping(to: r) else { return nil }
        let block: CGFloat = 28
        let cols = mosaicCellCount(length: r.width, block: block)
        let rows = mosaicCellCount(length: r.height, block: block)
        return scaled(cropped, width: cols, height: rows, interpolation: .medium)
    }

    private func mosaicCellCount(length: CGFloat, block: CGFloat) -> Int {
        guard length >= 2 else { return 1 }
        let count = Int((length / block).rounded(.down))
        return max(length >= block ? 2 : 1, min(48, count))
    }

    /// CGImage를 지정 크기로 다시 그려 새 CGImage를 만든다(보간 품질 지정).
    private func scaled(_ src: CGImage, width: Int, height: Int, interpolation: CGInterpolationQuality) -> CGImage? {
        guard width > 0, height > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = interpolation
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private func backingImageCG() -> CGImage? {
        if let backingCG { return backingCG }
        backingCG = backingImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return backingCG
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

    private func showTextEditor(for pending: PendingTextAnnotation) {
        cancelActiveTextField()
        pendingTextAnnotation = pending

        let fontSize = textFontSize(width: pending.width)
        let text = pending.initialText
        let frame: CGRect
        if pending.kind == .callout {
            let bubble = calloutTextRect(text: text, anchor: pending.end, width: pending.width)
            frame = calloutEditorFrame(in: bubble, width: pending.width)
        } else {
            let fieldSize = CGSize(width: 220, height: max(28, fontSize + 10))
            frame = CGRect(origin: textEditorOrigin(anchor: pending.end, size: fieldSize), size: fieldSize)
        }

        let field = InlineTextField(frame: frame)
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = pending.color
        field.stringValue = text
        field.placeholderString = pending.kind == .callout ? "말풍선 텍스트" : "텍스트"
        field.focusRingType = .none
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.bezelStyle = .roundedBezel
        field.onCommit = { [weak self] in self?.commitActiveTextField() }
        field.onCancel = { [weak self] in self?.cancelActiveTextField() }
        field.onChange = { [weak self] in self?.updateActiveTextFieldFrame() }
        field.target = self
        field.action = #selector(inlineTextCommitted)
        addSubview(field)
        activeTextField = field
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func updateActiveTextFieldFrame() {
        guard let field = activeTextField, let pending = pendingTextAnnotation, pending.kind == .callout else {
            needsDisplay = true
            return
        }
        let bubble = calloutTextRect(text: field.stringValue, anchor: pending.end, width: pending.width)
        field.frame = calloutEditorFrame(in: bubble, width: pending.width)
        needsDisplay = true
    }

    private func textEditorOrigin(anchor: CGPoint, size: CGSize) -> CGPoint {
        let margin: CGFloat = 6
        return CGPoint(x: min(max(margin, anchor.x), max(margin, bounds.width - size.width - margin)),
                       y: min(max(margin, anchor.y), max(margin, bounds.height - size.height - margin)))
    }

    @objc private func inlineTextCommitted() {
        commitActiveTextField()
    }

    private func commitActiveTextField() {
        guard let field = activeTextField, let pending = pendingTextAnnotation else {
            cancelActiveTextField()
            return
        }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        activeTextField = nil
        pendingTextAnnotation = nil
        window?.makeFirstResponder(self)
        guard !value.isEmpty else {
            needsDisplay = true
            return
        }

        let kind: Annotation.Kind = pending.kind == .callout ? .callout(value) : .text(value)
        if let index = pending.editingIndex, annotations.indices.contains(index) {
            guard !sameText(kind, as: annotations[index].kind) else {
                needsDisplay = true
                return
            }
            pushUndo()
            annotations[index].kind = kind
        } else {
            pushUndo()
            annotations.append(Annotation(kind: kind, start: pending.start, end: pending.end,
                                          color: pending.color, width: pending.width))
        }
        needsDisplay = true
    }

    private func sameText(_ lhs: Annotation.Kind, as rhs: Annotation.Kind) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)), (.callout(let a), .callout(let b)):
            return a == b
        default:
            return false
        }
    }

    private func cancelActiveTextField() {
        activeTextField?.removeFromSuperview()
        activeTextField = nil
        pendingTextAnnotation = nil
        dragStart = nil
        dragCurrent = nil
        annotationDrag = nil
        needsDisplay = true
    }

    private func textFontSize(width: CGFloat) -> CGFloat {
        min(72, max(16, width * 5.2))
    }

    private func textAttributes(color: NSColor, width: CGFloat, alpha: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: textFontSize(width: width), weight: .semibold),
            .foregroundColor: color.withAlphaComponent(alpha)
        ]
    }

    private func drawText(_ value: String, at point: CGPoint, color: NSColor, width: CGFloat, alpha: CGFloat = 1) {
        (value as NSString).draw(at: point, withAttributes: textAttributes(color: color, width: width, alpha: alpha))
    }

    private func textRect(_ value: String, at point: CGPoint, width: CGFloat) -> CGRect {
        let size = (value as NSString).size(withAttributes: textAttributes(color: .labelColor, width: width))
        return CGRect(origin: point, size: size)
    }

    private func calloutTextRect(text: String, anchor: CGPoint, width: CGFloat) -> CGRect {
        let attributes = textAttributes(color: .labelColor, width: width)
        let effectiveText = text.isEmpty ? "말풍선 텍스트" : text
        let textSize = (effectiveText as NSString).size(withAttributes: attributes)
        let padding = max(10, textFontSize(width: width) * 0.42)
        let bubbleSize = CGSize(width: max(90, min(360, textSize.width + padding * 2)),
                                height: max(38, textSize.height + padding * 1.55))
        return CGRect(origin: textEditorOrigin(anchor: anchor, size: bubbleSize), size: bubbleSize)
    }

    private func calloutEditorFrame(in bubble: CGRect, width: CGFloat) -> CGRect {
        let padding = max(10, textFontSize(width: width) * 0.42)
        return bubble.insetBy(dx: padding, dy: max(6, padding * 0.35))
    }

    private func drawCallout(text: String, head: CGPoint, bubbleAnchor: CGPoint,
                             color: NSColor, width: CGFloat, alpha: CGFloat = 1, drawsText: Bool = true) {
        let displayText = text.isEmpty ? "말풍선 텍스트" : text
        let bubble = calloutTextRect(text: displayText, anchor: bubbleAnchor, width: width)
        let radius = max(10, width * 2.2)
        let path = NSBezierPath(roundedRect: bubble, xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.94 * alpha).setFill()
        path.fill()
        color.withAlphaComponent(alpha).setStroke()
        path.lineWidth = max(1.5, width)
        path.stroke()

        let attach = pointOn(rect: bubble, toward: head)
        color.withAlphaComponent(alpha).setStroke()
        color.withAlphaComponent(alpha).setFill()
        drawArrow(from: attach, to: head, width: max(2, width))

        let padding = max(10, textFontSize(width: width) * 0.42)
        let textPoint = CGPoint(x: bubble.minX + padding,
                                y: bubble.minY + (bubble.height - textFontSize(width: width) * 1.2) / 2)
        if drawsText {
            drawText(displayText, at: textPoint, color: color, width: width, alpha: alpha)
        }
    }

    private func pointOn(rect: CGRect, toward point: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let scaleX = dx == 0 ? CGFloat.greatestFiniteMagnitude : (rect.width / 2) / abs(dx)
        let scaleY = dy == 0 ? CGFloat.greatestFiniteMagnitude : (rect.height / 2) / abs(dy)
        let scale = min(scaleX, scaleY)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
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

        // 모서리·변 선택점 (가운데 점은 표시하지 않음 — 안쪽을 드래그하면 이동은 그대로 됨)
        let handleSize = 12 / zoomScale
        for (handle, position) in handlePoints(rect) where handle != .center {
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

private final class InlineTextField: NSTextField {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onChange: (() -> Void)?

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onChange?()
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onCommit?()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
