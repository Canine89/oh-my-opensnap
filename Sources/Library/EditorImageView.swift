import AppKit

/// 라이브러리 미리보기 겸 간단 편집 뷰.
/// 도구: 크롭(핸들 방식) / 중간 잘라내기 / 번호(➊–➒) / 텍스트 / 말풍선 / 화살표 / 사각형 / 원. 좌상단 원점(isFlipped).
/// 좌표는 이미지 픽셀과 1:1. 로드 시 DPI 메타데이터와 무관하게 실제 픽셀 크기로 정규화한다.
/// ⌘Z 되돌리기는 스냅샷 스택으로 크롭 포함 모든 편집에 적용된다.
final class EditorImageView: NSView {

    enum Tool { case none, crop, cutHorizontal, cutVertical, number, text, callout, arrow, rectangle, ellipse, mosaic }

    struct Annotation {
        enum Kind { case number(Int), text(String), callout(String), arrow, rectangle, ellipse, mosaic }
        var kind: Kind
        var start: CGPoint
        var end: CGPoint
        var calloutBubble: CGRect?
        var color: NSColor
        var width: CGFloat
        /// 모자이크 전용: 영역을 다운샘플한 작은 이미지(그릴 때 보간 없이 확대 → 블록).
        var mosaicImage: CGImage? = nil

        init(kind: Kind, start: CGPoint, end: CGPoint, color: NSColor, width: CGFloat,
             calloutBubble: CGRect? = nil, mosaicImage: CGImage? = nil) {
            self.kind = kind
            self.start = start
            self.end = end
            self.calloutBubble = calloutBubble
            self.color = color
            self.width = width
            self.mosaicImage = mosaicImage
        }
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
        let calloutBubble: CGRect?

        init(kind: Kind, start: CGPoint, end: CGPoint, color: NSColor, width: CGFloat,
             editingIndex: Int? = nil, initialText: String = "", calloutBubble: CGRect? = nil) {
            self.kind = kind
            self.start = start
            self.end = end
            self.color = color
            self.width = width
            self.editingIndex = editingIndex
            self.initialText = initialText
            self.calloutBubble = calloutBubble
        }
    }

    private struct AnnotationDrag {
        enum Kind: Equatable { case object, calloutBubble, calloutHead, corner(Handle), arrowStart, arrowEnd }
        let kind: Kind
        let index: Int
        let origin: CGPoint
        let initialStart: CGPoint
        let initialEnd: CGPoint
        let initialBubble: CGRect?
        var didMove = false
        var didPushUndo = false
    }

    private struct Snapshot {
        let image: NSImage?
        let annotations: [Annotation]
        let nextNumber: Int
        let cropRect: CGRect?      // 크롭 범위도 되돌림 대상
    }

    private struct MiddleCutSelection {
        let axis: MiddleCutAxis
        let lower: CGFloat
        let upper: CGFloat
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
            selectedAnnotationIndex = nil
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
            onToolChanged?(tool)
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
    /// 내부 이벤트로 도구가 바뀌면 툴바 선택 상태도 맞추도록 알린다.
    var onToolChanged: ((Tool) -> Void)?
    /// 선택된 주석이 바뀌면(없어지면 nil) 알린다 → 툴바의 색·굵기를 그 주석에 맞춘다.
    var onSelectionChanged: ((Annotation?) -> Void)?
    /// 주석 목록이 바뀔 때마다(추가·삭제·이동·스타일·되돌리기) 한 런루프에 한 번 알린다 → 사이드카 저장.
    var onAnnotationsChanged: (() -> Void)?

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// 예약된 주석 변경 알림이 있으면 지금 보낸다(항목을 바꾸기 직전에 호출해 마지막 편집을 잃지 않게).
    func flushPendingAnnotationChanges() {
        if activeTextField != nil { commitActiveTextField() }
        guard annotationsChangeScheduled else { return }
        annotationsChangeScheduled = false
        onAnnotationsChanged?()
    }

    // MARK: 사이드카 직렬화
    /// 저장용 표현. 모자이크의 다운샘플 이미지는 저장하지 않고 복원 시 원본에서 다시 만든다.
    private struct AnnotationRecord: Codable {
        var kind: String
        var number: Int?
        var text: String?
        var start: [CGFloat]
        var end: [CGFloat]
        var bubble: [CGFloat]?
        var color: [CGFloat]
        var width: CGFloat
    }

    private struct AnnotationDocument: Codable {
        var version: Int
        var nextNumber: Int
        var annotations: [AnnotationRecord]
    }

    /// 현재 주석을 JSON으로. 주석이 없으면 nil(사이드카 삭제 신호).
    func annotationsData() -> Data? {
        guard !annotations.isEmpty else { return nil }
        let records = annotations.map { a -> AnnotationRecord in
            var record = AnnotationRecord(kind: "", number: nil, text: nil,
                                          start: [a.start.x, a.start.y], end: [a.end.x, a.end.y],
                                          bubble: a.calloutBubble.map { [$0.minX, $0.minY, $0.width, $0.height] },
                                          color: Self.components(of: a.color), width: a.width)
            switch a.kind {
            case .number(let n): record.kind = "number"; record.number = n
            case .text(let t): record.kind = "text"; record.text = t
            case .callout(let t): record.kind = "callout"; record.text = t
            case .arrow: record.kind = "arrow"
            case .rectangle: record.kind = "rectangle"
            case .ellipse: record.kind = "ellipse"
            case .mosaic: record.kind = "mosaic"
            }
            return record
        }
        return try? JSONEncoder().encode(AnnotationDocument(version: 1, nextNumber: nextNumber, annotations: records))
    }

    /// 사이드카에서 주석을 복원한다. 되돌리기 스택에는 넣지 않고, 저장 알림도 내지 않는다.
    func restoreAnnotations(from data: Data) {
        guard let document = try? JSONDecoder().decode(AnnotationDocument.self, from: data) else { return }
        var restored: [Annotation] = []
        for r in document.annotations {
            guard r.start.count == 2, r.end.count == 2, r.color.count == 4 else { continue }
            let start = CGPoint(x: r.start[0], y: r.start[1])
            let end = CGPoint(x: r.end[0], y: r.end[1])
            let color = NSColor(srgbRed: r.color[0], green: r.color[1], blue: r.color[2], alpha: r.color[3])
            let bubble: CGRect? = (r.bubble?.count == 4)
                ? CGRect(x: r.bubble![0], y: r.bubble![1], width: r.bubble![2], height: r.bubble![3]) : nil
            let kind: Annotation.Kind
            var mosaic: CGImage? = nil
            switch r.kind {
            case "number": kind = .number(r.number ?? 1)
            case "text": kind = .text(r.text ?? "")
            case "callout": kind = .callout(r.text ?? "")
            case "arrow": kind = .arrow
            case "rectangle": kind = .rectangle
            case "ellipse": kind = .ellipse
            case "mosaic":
                kind = .mosaic
                mosaic = makeMosaicSmall(rect: Self.rect(start, end))
            default: continue
            }
            restored.append(Annotation(kind: kind, start: start, end: end, color: color, width: r.width,
                                       calloutBubble: bubble, mosaicImage: mosaic))
        }
        suppressAnnotationsChanged = true
        annotations = restored
        nextNumber = max(1, min(9, document.nextNumber))
        suppressAnnotationsChanged = false
        needsDisplay = true
    }

    private static func components(of color: NSColor) -> [CGFloat] {
        let c = color.usingColorSpace(.sRGB) ?? color
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    /// 현재 선택된 주석 (없으면 nil).
    var selectedAnnotation: Annotation? {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return nil }
        return annotations[index]
    }

    /// 선택된 주석의 색/굵기를 바꾼다. 같은 종류(undoKey)의 연속 변경(슬라이더 드래그 등)은 undo 한 번으로 묶는다.
    /// 텍스트·말풍선은 굵기가 글자 크기를 정하므로 말풍선 크기도 다시 계산한다. 모자이크는 대상이 아니다.
    func applyStyleToSelection(color: NSColor? = nil, width: CGFloat? = nil, undoKey: String) {
        if activeTextField != nil { commitActiveTextField() }
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        if case .mosaic = annotations[index].kind { return }
        let current = annotations[index]
        let colorChanged = color.map { $0 != current.color } ?? false
        let widthChanged = width.map { abs($0 - current.width) > 0.01 } ?? false
        guard colorChanged || widthChanged else { return }

        if styleUndoKey != undoKey {
            pushUndo()
            styleUndoKey = undoKey
        }
        if let color { annotations[index].color = color }
        if let width, widthChanged {
            annotations[index].width = width
            if case .callout(let text) = current.kind, let bubble = current.calloutBubble {
                let resized = calloutTextRect(text: text, anchor: bubble.origin, width: width)
                annotations[index].calloutBubble = resized
                annotations[index].end = resized.origin
            }
        }
        needsDisplay = true
    }

    /// 새 이미지 로드 (편집/undo 전부 초기화).
    var image: NSImage? {
        get { backingImage }
        set { load(newValue) }
    }

    // MARK: 내부 상태
    private var backingImage: NSImage? { didSet { backingCG = nil } }
    /// 모자이크 샘플링용 backingImage의 CGImage 캐시.
    private var backingCG: CGImage?
    private var annotations: [Annotation] = [] {
        didSet { scheduleAnnotationsChanged() }
    }
    private var annotationsChangeScheduled = false
    private var suppressAnnotationsChanged = false
    private var nextNumber = 1
    private var history = EditHistory<Snapshot>()

    private func scheduleAnnotationsChanged() {
        guard !suppressAnnotationsChanged, !annotationsChangeScheduled else { return }
        annotationsChangeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.annotationsChangeScheduled else { return }
            self.annotationsChangeScheduled = false
            self.onAnnotationsChanged?()
        }
    }

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var activeTextField: InlineTextField?
    private var pendingTextAnnotation: PendingTextAnnotation?
    private var annotationDrag: AnnotationDrag?
    private var selectedAnnotationIndex: Int? {
        didSet {
            guard oldValue != selectedAnnotationIndex else { return }
            styleUndoKey = nil
            onSelectionChanged?(selectedAnnotation)
        }
    }
    /// 선택 스타일 변경의 undo 묶음 키("color"/"width"/"nudge"). 선택이 바뀌면 초기화.
    private var styleUndoKey: String?

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

    /// 이미지 바깥 여백 클릭: 선택만 해제한다. 크롭 중이면 크롭을 취소하고,
    /// 다른 도구는 유지해 "화살표를 골랐는데 여백을 잘못 눌러 도구가 풀리는" 일을 막는다.
    func cancelSelectionAndToolFromMarginClick() {
        if activeTextField != nil { commitActiveTextField() }
        selectedAnnotationIndex = nil
        annotationDrag = nil
        dragStart = nil
        dragCurrent = nil
        if tool == .crop { tool = .none }
        needsDisplay = true
    }

    // MARK: 이미지 로드/교체
    private func load(_ image: NSImage?) {
        cancelActiveTextField()
        backingImage = pixelSizedImage(image)
        suppressAnnotationsChanged = true
        annotations.removeAll()
        suppressAnnotationsChanged = false
        annotationsChangeScheduled = false     // 이전 이미지의 예약 알림은 flush로 이미 처리됐거나 무효
        selectedAnnotationIndex = nil
        nextNumber = 1
        history.reset()
        cropRect = (tool == .crop) ? CGRect(origin: .zero, size: backingImage?.size ?? .zero) : nil
        if let size = backingImage?.size { setFrameSize(size) }
        onImageChanged?()
        notifyCropProgress()
        needsDisplay = true
    }

    /// PNG의 DPI 메타데이터가 Retina 캡처의 논리 크기(point)를 가리킬 수 있다.
    /// 에디터는 이미지 좌표를 곧 출력 픽셀로 쓰므로, 여기서 실제 CGImage 픽셀 크기로 맞춘다.
    /// 그렇지 않으면 재복사 시 2x 캡처가 절반 해상도 캔버스에 다시 그려진다.
    private func pixelSizedImage(_ image: NSImage?) -> NSImage? {
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return image }

        let pixelSize = NSSize(width: cg.width, height: cg.height)
        guard abs(image.size.width - pixelSize.width) > 0.01
                || abs(image.size.height - pixelSize.height) > 0.01
        else { return image }
        return NSImage(cgImage: cg, size: pixelSize)
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

    // MARK: Undo / Redo
    private func currentSnapshot(cropRect override: CGRect? = nil) -> Snapshot {
        Snapshot(image: backingImage, annotations: annotations,
                 nextNumber: nextNumber, cropRect: override ?? cropRect)
    }

    private func pushUndo() {
        history.record(currentSnapshot())
    }

    private func pushCropSnapshot(_ rect: CGRect) {
        history.record(currentSnapshot(cropRect: rect))
    }

    func undo() {
        guard let snapshot = history.undo(current: currentSnapshot()) else { return }
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = history.redo(current: currentSnapshot()) else { return }
        restore(snapshot)
    }

    private func restore(_ snapshot: Snapshot) {
        // 이미지 인스턴스가 달라지면(=크롭 적용/해제) 디스크 파일도 되돌려야 한다.
        let imageChanged = snapshot.image !== backingImage
        backingImage = snapshot.image
        annotations = snapshot.annotations
        nextNumber = snapshot.nextNumber
        cropRect = snapshot.cropRect      // 크롭 범위 조정도 되돌린다
        activeHandle = nil
        annotationDrag = nil
        selectedAnnotationIndex = nil
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
        let wasEditingText = activeTextField != nil
        if wasEditingText {
            commitActiveTextField()
            tool = .none
        }
        window?.makeFirstResponder(self)
        let rawPoint = convert(event.locationInWindow, from: nil)
        let point = clamp(rawPoint)
        // 어떤 도구가 켜져 있든 기존 주석 위를 클릭하면 그 주석을 잡아 옮기는 게 우선이다.
        // 주석 위에 겹쳐서 새로 그리고 싶을 때만 ⌥(option)을 누른 채 드래그한다.
        let canSelect = tool != .crop && !event.modifierFlags.contains(.option)
        if tool != .crop, let index = selectedAnnotationIndex, let handle = hitSelectedHandle(at: point) {
            beginDrag(index: index, kind: handle, at: point)
            return
        }
        if canSelect, event.clickCount >= 2, let hit = hitAnnotation(at: point) {
            selectedAnnotationIndex = hit.index
            beginEditingAnnotation(at: hit.index, dragKind: hit.kind)
            return
        }
        if canSelect, beginAnnotationDrag(at: point, allowedKinds: [.object, .calloutHead, .calloutBubble]) {
            return
        }
        if wasEditingText {
            selectedAnnotationIndex = nil
            needsDisplay = true
            return
        }
        selectedAnnotationIndex = nil
        switch tool {
        case .number:
            pushUndo()
            annotations.append(Annotation(kind: .number(nextNumber), start: point, end: point,
                                          color: strokeColor, width: strokeWidth))
            selectedAnnotationIndex = annotations.count - 1
            nextNumber = nextNumber >= 9 ? 1 : nextNumber + 1
            hoverPoint = nil    // 방금 찍은 자리와 겹치지 않게; 커서를 움직이면 다음 번호 미리보기가 다시 뜬다
            needsDisplay = true
        case .crop:
            if !bounds.contains(rawPoint), handle(at: point) == nil {
                cancelSelectionAndToolFromMarginClick()
                return
            }
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
        case .cutHorizontal, .cutVertical, .arrow, .rectangle, .ellipse, .mosaic:
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
        case .cutHorizontal, .cutVertical, .mosaic:
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
            selectedAnnotationIndex = annotations.count - 1
            needsDisplay = true
        case .callout:
            defer { dragStart = nil; dragCurrent = nil }
            guard let start = dragStart else { return }
            let end = clamp(convert(event.locationInWindow, from: nil))
            guard hypot(end.x - start.x, end.y - start.y) > 8 else { return }
            let bubble = calloutTextRect(text: "", anchor: end, width: strokeWidth)
            showTextEditor(for: PendingTextAnnotation(kind: .callout, start: start, end: end,
                                                      color: strokeColor, width: strokeWidth,
                                                      calloutBubble: bubble))
        case .cutHorizontal, .cutVertical:
            defer { dragStart = nil; dragCurrent = nil; needsDisplay = true }
            guard let start = dragStart else { return }
            let end = clamp(convert(event.locationInWindow, from: nil))
            applyMiddleCut(from: start, to: end)
        case .mosaic:
            defer { dragStart = nil; dragCurrent = nil }
            guard let start = dragStart else { return }
            let end = clamp(convert(event.locationInWindow, from: nil))
            let rect = Self.rect(start, end)
            guard rect.width > 4, rect.height > 4, let small = makeMosaicSmall(rect: rect) else { return }
            pushUndo()
            annotations.append(Annotation(kind: .mosaic, start: start, end: end,
                                          color: .clear, width: 0, mosaicImage: small))
            selectedAnnotationIndex = annotations.count - 1
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
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z": if event.modifierFlags.contains(.shift) { redo() } else { undo() }; return true
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
        case 36, 76:
            if activeTextField != nil {
                commitActiveTextField()
            } else if tool == .crop {
                applyCrop()             // Return / Enter
            } else {
                editSelectedAnnotation()
            }
        case 51, 117:
            deleteSelectedAnnotation()
        case 53:
            selectedAnnotationIndex = nil
            tool = .none                 // Esc → 선택/크롭 취소
        case 123, 124, 125, 126:
            guard selectedAnnotationIndex != nil, activeTextField == nil else {
                super.keyDown(with: event)
                return
            }
            // ← → ↓ ↑ : 선택 주석을 1px(⇧ 10px) 이동
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0)
            let dy: CGFloat = event.keyCode == 126 ? -step : (event.keyCode == 125 ? step : 0)
            nudgeSelection(dx: dx, dy: dy)
        default: super.keyDown(with: event)
        }
    }

    private func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        if styleUndoKey != "nudge" {
            pushUndo()
            styleUndoKey = "nudge"
        }
        let annotation = annotations[index]
        let rect = selectionRect(for: annotation)
        let offset = CGPoint(x: min(max(dx, bounds.minX - rect.minX), bounds.maxX - rect.maxX),
                             y: min(max(dy, bounds.minY - rect.minY), bounds.maxY - rect.maxY))
        annotations[index].start = CGPoint(x: annotation.start.x + offset.x, y: annotation.start.y + offset.y)
        annotations[index].end = CGPoint(x: annotation.end.x + offset.x, y: annotation.end.y + offset.y)
        if let bubble = annotation.calloutBubble {
            annotations[index].calloutBubble = bubble.offsetBy(dx: offset.x, dy: offset.y)
        }
        needsDisplay = true
    }

    // 표준 Edit 메뉴(⌘Z/⌘C) 라우팅용 responder 액션
    @objc func undo(_ sender: Any?) { undo() }
    @objc func redo(_ sender: Any?) { redo() }
    @objc func copy(_ sender: Any?) { copyToClipboard() }
    @objc func delete(_ sender: Any?) { deleteSelectedAnnotation() }

    // MARK: 크롭
    private func applyCrop() {
        guard tool == .crop, let rect = cropRect, let cg = renderedCGImage() else { return }
        let pxRect = rect.integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !pxRect.isEmpty, let cropped = cg.cropping(to: pxRect) else { return }
        pushUndo()
        replaceImage(NSImage(cgImage: cropped, size: pxRect.size), annotations: [], nextNumber: 1)
        onEditCommitted?()      // 크롭 결과를 라이브러리 파일에 반영
    }

    // MARK: 중간 잘라내기
    /// 띠의 방향은 도구가 정한다 — 가로 자르기는 가로 띠(높이 감소), 세로 자르기는 세로 띠(너비 감소).
    /// 드래그 방향을 추측하지 않으므로 어느 방향으로 끌든 결과가 같다.
    /// 제거된 두 조각은 서로 당기되 최대 24px의 투명 간격을 남긴다.
    private var middleCutAxis: MiddleCutAxis? {
        switch tool {
        case .cutHorizontal: return .horizontalStrip
        case .cutVertical: return .verticalStrip
        default: return nil
        }
    }

    private func applyMiddleCut(from start: CGPoint, to end: CGPoint) {
        guard let axis = middleCutAxis, let source = renderedCGImage() else { return }
        let selection = middleCutSelection(from: start, to: end)
        let sourceWidth = source.width
        let sourceHeight = source.height

        let axisLength: Int
        switch axis {
        case .verticalStrip:
            axisLength = sourceWidth
        case .horizontalStrip:
            axisLength = sourceHeight
        }

        let cutStart = max(0, min(axisLength, Int(floor(selection.lower))))
        let cutEnd = max(0, min(axisLength, Int(ceil(selection.upper))))
        let removedLength = cutEnd - cutStart
        // 짧은 실수 드래그와 한쪽 조각이 전혀 남지 않는 선택은 적용하지 않는다.
        guard removedLength >= 12, cutStart > 0, cutEnd < axisLength else { return }

        let transparentGap = min(24, max(6, Int((CGFloat(removedLength) * 0.12).rounded())))
        guard let result = MiddleCutRenderer.makeImage(source: source, axis: axis,
                                                       cutStart: cutStart, cutEnd: cutEnd,
                                                       transparentGap: transparentGap) else { return }
        pushUndo()
        replaceImage(result, annotations: [], nextNumber: 1)
        onEditCommitted?()
    }

    private func middleCutSelection(from start: CGPoint, to end: CGPoint) -> MiddleCutSelection {
        let axis = middleCutAxis ?? .horizontalStrip
        switch axis {
        case .verticalStrip:
            return MiddleCutSelection(axis: axis, lower: min(start.x, end.x), upper: max(start.x, end.x))
        case .horizontalStrip:
            return MiddleCutSelection(axis: axis, lower: min(start.y, end.y), upper: max(start.y, end.y))
        }
    }

    private func middleCutRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let selection = middleCutSelection(from: start, to: end)
        switch selection.axis {
        case .verticalStrip:
            return CGRect(x: selection.lower, y: 0,
                          width: selection.upper - selection.lower, height: bounds.height)
        case .horizontalStrip:
            return CGRect(x: 0, y: selection.lower,
                          width: bounds.width, height: selection.upper - selection.lower)
        }
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
        beginDrag(index: hit.index, kind: hit.kind, at: point)
        return true
    }

    /// 선택된 주석의 조절 핸들: 도형·모자이크는 네 모서리, 화살표는 양 끝, 말풍선은 머리.
    private func hitSelectedHandle(at point: CGPoint) -> AnnotationDrag.Kind? {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return nil }
        let a = annotations[index]
        let radius = max(8, 10 / zoomScale)
        func near(_ p: CGPoint) -> Bool { hypot(point.x - p.x, point.y - p.y) <= radius }
        switch a.kind {
        case .rectangle, .ellipse, .mosaic:
            let r = Self.rect(a.start, a.end)
            let corners: [(Handle, CGPoint)] = [
                (.topLeft, CGPoint(x: r.minX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottomLeft, CGPoint(x: r.minX, y: r.maxY))
            ]
            return corners.first { near($0.1) }.map { .corner($0.0) }
        case .arrow:
            if near(a.end) { return .arrowEnd }
            if near(a.start) { return .arrowStart }
            return nil
        case .callout:
            let headRadius = max(10 / zoomScale, a.width * 4)
            return hypot(point.x - a.start.x, point.y - a.start.y) <= headRadius ? .calloutHead : nil
        default:
            return nil
        }
    }

    private func beginDrag(index: Int, kind: AnnotationDrag.Kind, at point: CGPoint) {
        guard annotations.indices.contains(index) else { return }
        let hit = (index: index, kind: kind)
        let annotation = annotations[hit.index]
        let initialBubble: CGRect?
        if case .callout(let value) = annotation.kind {
            initialBubble = calloutRect(for: annotation, text: value)
        } else {
            initialBubble = nil
        }
        selectedAnnotationIndex = hit.index
        annotationDrag = AnnotationDrag(kind: hit.kind, index: hit.index, origin: point,
                                        initialStart: annotation.start, initialEnd: annotation.end,
                                        initialBubble: initialBubble)
    }

    private func updateAnnotationDrag(to point: CGPoint) -> Bool {
        guard var drag = annotationDrag, annotations.indices.contains(drag.index) else { return false }
        let dx = point.x - drag.origin.x
        let dy = point.y - drag.origin.y
        guard drag.didMove || hypot(dx, dy) > max(2, 3 / zoomScale) else { return true }
        if !drag.didPushUndo {
            pushUndo()
            drag.didPushUndo = true
            styleUndoKey = nil
        }
        drag.didMove = true
        switch drag.kind {
        case .object:
            let offset = constrainedAnnotationOffset(dx: dx, dy: dy, drag: drag)
            let start = CGPoint(x: drag.initialStart.x + offset.x, y: drag.initialStart.y + offset.y)
            let end = CGPoint(x: drag.initialEnd.x + offset.x, y: drag.initialEnd.y + offset.y)
            annotations[drag.index].start = start
            annotations[drag.index].end = end
        case .calloutBubble:
            if let bubble = drag.initialBubble {
                let origin = clampBubbleOrigin(CGPoint(x: bubble.origin.x + dx, y: bubble.origin.y + dy),
                                               size: bubble.size)
                annotations[drag.index].calloutBubble = CGRect(origin: origin, size: bubble.size)
                annotations[drag.index].end = origin
            } else {
                annotations[drag.index].end = clamp(CGPoint(x: drag.initialEnd.x + dx, y: drag.initialEnd.y + dy))
            }
        case .calloutHead:
            annotations[drag.index].start = point
        case .corner(let handle):
            // 잡은 모서리의 반대편을 고정하고 잡은 쪽을 커서로. min/max 정규화로 뒤집혀도 자연스럽다.
            let r = Self.rect(drag.initialStart, drag.initialEnd)
            let fixed: CGPoint
            switch handle {
            case .topLeft: fixed = CGPoint(x: r.maxX, y: r.maxY)
            case .topRight: fixed = CGPoint(x: r.minX, y: r.maxY)
            case .bottomLeft: fixed = CGPoint(x: r.maxX, y: r.minY)
            default: fixed = CGPoint(x: r.minX, y: r.minY)
            }
            annotations[drag.index].start = CGPoint(x: min(fixed.x, point.x), y: min(fixed.y, point.y))
            annotations[drag.index].end = CGPoint(x: max(fixed.x, point.x), y: max(fixed.y, point.y))
        case .arrowStart:
            annotations[drag.index].start = point
        case .arrowEnd:
            annotations[drag.index].end = point
        }
        annotationDrag = drag
        needsDisplay = true
        return true
    }

    private func constrainedAnnotationOffset(dx: CGFloat, dy: CGFloat, drag: AnnotationDrag) -> CGPoint {
        guard annotations.indices.contains(drag.index) else { return CGPoint(x: dx, y: dy) }
        let current = annotations[drag.index]
        let initial = Annotation(kind: current.kind,
                                 start: drag.initialStart,
                                 end: drag.initialEnd,
                                 color: current.color,
                                 width: current.width,
                                 calloutBubble: drag.initialBubble ?? current.calloutBubble,
                                 mosaicImage: current.mosaicImage)
        let rect = selectionRect(for: initial)
        let minDX = bounds.minX - rect.minX
        let maxDX = bounds.maxX - rect.maxX
        let minDY = bounds.minY - rect.minY
        let maxDY = bounds.maxY - rect.maxY
        return CGPoint(x: min(max(dx, minDX), maxDX),
                       y: min(max(dy, minDY), maxDY))
    }

    private func finishAnnotationDrag() -> Bool {
        guard let drag = annotationDrag else { return false }
        annotationDrag = nil
        // 모자이크 크기를 바꿨으면 새 영역의 픽셀로 다시 샘플링
        if case .corner = drag.kind, drag.didMove, annotations.indices.contains(drag.index),
           case .mosaic = annotations[drag.index].kind {
            let a = annotations[drag.index]
            annotations[drag.index].mosaicImage = makeMosaicSmall(rect: Self.rect(a.start, a.end))
        }
        needsDisplay = true
        return true
    }

    private func editSelectedAnnotation() {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        switch annotations[index].kind {
        case .text:
            beginEditingAnnotation(at: index, dragKind: .object)
        case .callout:
            beginEditingAnnotation(at: index, dragKind: .calloutBubble)
        default:
            break
        }
    }

    private func deleteSelectedAnnotation() {
        guard activeTextField == nil,
              let index = selectedAnnotationIndex,
              annotations.indices.contains(index)
        else { return }
        pushUndo()
        annotations.remove(at: index)
        selectedAnnotationIndex = nil
        annotationDrag = nil
        needsDisplay = true
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
                                                      editingIndex: index, initialText: value,
                                                      calloutBubble: annotation.calloutBubble))
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
                    return (index, .object)
                }
            case .callout(let value):
                let headRadius = max(10 / zoomScale, annotation.width * 4)
                if hypot(point.x - annotation.start.x, point.y - annotation.start.y) <= headRadius {
                    return (index, .calloutHead)
                }
                if calloutRect(for: annotation, text: value)
                    .insetBy(dx: -hitInset, dy: -hitInset)
                    .contains(point) {
                    return (index, .calloutBubble)
                }
            case .number:
                if selectionRect(for: annotation).insetBy(dx: -hitInset, dy: -hitInset).contains(point) {
                    return (index, .object)
                }
            case .arrow:
                if distanceFromPoint(point, toSegmentFrom: annotation.start, to: annotation.end) <= hitInset + annotation.width {
                    return (index, .object)
                }
            case .rectangle:
                if Self.rect(annotation.start, annotation.end).insetBy(dx: -hitInset, dy: -hitInset).contains(point) {
                    return (index, .object)
                }
            case .ellipse:
                if ellipseHit(point, in: Self.rect(annotation.start, annotation.end), tolerance: hitInset + annotation.width) {
                    return (index, .object)
                }
            case .mosaic:
                if Self.rect(annotation.start, annotation.end).insetBy(dx: -hitInset, dy: -hitInset).contains(point) {
                    return (index, .object)
                }
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

    /// 원본 위치에 합성본을 저장할 때도 되돌릴 수 있는 하나의 편집으로 처리한다.
    func commitFlattenedImage() {
        guard let cg = renderedCGImage() else { return }
        pushUndo()
        replaceImage(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), annotations: [], nextNumber: 1)
        onEditCommitted?()
    }

    /// 보관용 원본. 주석은 별도 저장하므로 여기서는 합성하지 않는다.
    func baseCGImage() -> CGImage? {
        backingImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
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
        Self.transparencyPattern.setFill()
        dirtyRect.fill()
        backingImage?.draw(in: bounds)
        for (index, annotation) in annotations.enumerated() where index != pendingTextAnnotation?.editingIndex {
            draw(annotation)
        }

        if let pending = pendingTextAnnotation, pending.kind == .callout, let field = activeTextField {
            drawCallout(text: field.stringValue, head: pending.start, bubbleAnchor: pending.end,
                        color: pending.color, width: pending.width,
                        bubble: activeCalloutBubble(text: field.stringValue, pending: pending),
                        drawsText: false)
        }

        if let index = selectedAnnotationIndex,
           index != pendingTextAnnotation?.editingIndex,
           annotations.indices.contains(index) {
            drawSelection(for: annotations[index])
        }

        if tool != .crop, let start = dragStart, let current = dragCurrent {
            switch tool {
        case .callout:
                drawCallout(text: "", head: start, bubbleAnchor: current,
                            color: strokeColor, width: strokeWidth,
                            bubble: calloutTextRect(text: "", anchor: current, width: strokeWidth),
                            alpha: 0.55)
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
            case .cutHorizontal, .cutVertical:
                drawMiddleCutOverlay(middleCutRect(from: start, to: current))
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
                        color: annotation.color, width: annotation.width,
                        bubble: annotation.calloutBubble)
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

    private func drawSelection(for annotation: Annotation) {
        let rect: CGRect
        switch annotation.kind {
        case .text(let value):
            rect = textRect(value, at: annotation.start, width: annotation.width)
                .insetBy(dx: -6 / zoomScale, dy: -5 / zoomScale)
        case .callout(let value):
            let bubble = calloutRect(for: annotation, text: value)
            rect = bubble.insetBy(dx: -4 / zoomScale, dy: -4 / zoomScale)
            drawSelectionHandle(at: annotation.start, fill: annotation.color, stroke: .white)
        default:
            rect = selectionRect(for: annotation)
                .insetBy(dx: -5 / zoomScale, dy: -5 / zoomScale)
        }
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5 / zoomScale
        path.setLineDash([5 / zoomScale, 4 / zoomScale], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        path.stroke()

        // 핸들은 실제로 잡히는 것만: 도형·모자이크는 모서리, 화살표는 양 끝. 텍스트·번호는 굵기로 크기를 바꾼다.
        switch annotation.kind {
        case .rectangle, .ellipse, .mosaic:
            let r = Self.rect(annotation.start, annotation.end)
            drawSelectionHandle(at: CGPoint(x: r.minX, y: r.minY))
            drawSelectionHandle(at: CGPoint(x: r.maxX, y: r.minY))
            drawSelectionHandle(at: CGPoint(x: r.maxX, y: r.maxY))
            drawSelectionHandle(at: CGPoint(x: r.minX, y: r.maxY))
        case .arrow:
            drawSelectionHandle(at: annotation.start, fill: annotation.color, stroke: .white)
            drawSelectionHandle(at: annotation.end, fill: annotation.color, stroke: .white)
        default:
            break
        }
    }

    private func selectionRect(for annotation: Annotation) -> CGRect {
        switch annotation.kind {
        case .number:
            let radius = max(12, annotation.width * 3.5)
            return CGRect(x: annotation.start.x - radius, y: annotation.start.y - radius,
                          width: radius * 2, height: radius * 2)
        case .text(let value):
            return textRect(value, at: annotation.start, width: annotation.width)
        case .callout(let value):
            return calloutRect(for: annotation, text: value)
        case .arrow:
            return Self.rect(annotation.start, annotation.end)
                .insetBy(dx: -max(8, annotation.width * 2), dy: -max(8, annotation.width * 2))
        case .rectangle, .ellipse, .mosaic:
            return Self.rect(annotation.start, annotation.end)
        }
    }

    private func drawSelectionHandle(at point: CGPoint, fill: NSColor = .white, stroke: NSColor = .black) {
        let size = 8 / zoomScale
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        fill.setFill()
        NSBezierPath(ovalIn: rect).fill()
        stroke.withAlphaComponent(0.65).setStroke()
        let outline = NSBezierPath(ovalIn: rect)
        outline.lineWidth = 1 / zoomScale
        outline.stroke()
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
            let bubble = activeCalloutBubble(text: text, pending: pending)
            frame = calloutEditorFrame(in: bubble, width: pending.width)
        } else {
            let fieldSize = CGSize(width: 220, height: max(28, fontSize + 10))
            frame = CGRect(origin: textEditorOrigin(anchor: pending.end, size: fieldSize), size: fieldSize)
        }

        let field = InlineTextField(frame: frame)
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = pending.color
        field.stringValue = text
        field.placeholderString = pending.kind == .callout ? loc("Callout text", "말풍선 텍스트") : loc("Text", "텍스트")
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
        let bubble = activeCalloutBubble(text: field.stringValue, pending: pending)
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
            return
        }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: Annotation.Kind = pending.kind == .callout ? .callout(value) : .text(value)
        let calloutBubble = pending.kind == .callout
            ? activeCalloutBubble(text: value, pending: pending)
            : nil

        activeTextField = nil
        pendingTextAnnotation = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !value.isEmpty else {
            needsDisplay = true
            return
        }

        if let index = pending.editingIndex, annotations.indices.contains(index) {
            guard !sameText(kind, as: annotations[index].kind) else {
                needsDisplay = true
                return
            }
            pushUndo()
            annotations[index].kind = kind
            annotations[index].calloutBubble = calloutBubble
            if let calloutBubble {
                annotations[index].end = calloutBubble.origin
            }
            selectedAnnotationIndex = index
        } else {
            pushUndo()
            annotations.append(Annotation(kind: kind, start: pending.start, end: pending.end,
                                          color: pending.color, width: pending.width,
                                          calloutBubble: calloutBubble))
            if let calloutBubble {
                annotations[annotations.count - 1].end = calloutBubble.origin
            }
            selectedAnnotationIndex = annotations.count - 1
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
        selectedAnnotationIndex = nil
        needsDisplay = true
    }

    private func textFontSize(width: CGFloat) -> CGFloat {
        min(72, max(16, width * 5.2))
    }

    private func textAttributes(color: NSColor, width: CGFloat, alpha: CGFloat = 1, halo: Bool = false) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: textFontSize(width: width), weight: .semibold),
            .foregroundColor: color.withAlphaComponent(alpha)
        ]
        if halo {
            // 배경과 무관하게 읽히도록 글자색 밝기의 반대 톤으로 부드러운 테두리를 두른다.
            let c = color.usingColorSpace(.sRGB) ?? color
            let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            let shadow = NSShadow()
            shadow.shadowColor = (luminance > 0.6 ? NSColor.black.withAlphaComponent(0.75)
                                                  : NSColor.white.withAlphaComponent(0.9)).withAlphaComponent(alpha)
            shadow.shadowBlurRadius = max(2, textFontSize(width: width) * 0.12)
            shadow.shadowOffset = .zero
            attributes[.shadow] = shadow
        }
        return attributes
    }

    private func drawText(_ value: String, at point: CGPoint, color: NSColor, width: CGFloat, alpha: CGFloat = 1, halo: Bool = true) {
        (value as NSString).draw(at: point, withAttributes: textAttributes(color: color, width: width, alpha: alpha, halo: halo))
    }

    private func textRect(_ value: String, at point: CGPoint, width: CGFloat) -> CGRect {
        let size = (value as NSString).size(withAttributes: textAttributes(color: .labelColor, width: width))
        return CGRect(origin: point, size: size)
    }

    private func calloutTextRect(text: String, anchor: CGPoint, width: CGFloat) -> CGRect {
        let attributes = textAttributes(color: .labelColor, width: width)
        let effectiveText = text.isEmpty ? loc("Callout text", "말풍선 텍스트") : text
        let textSize = (effectiveText as NSString).size(withAttributes: attributes)
        let padding = max(10, textFontSize(width: width) * 0.42)
        let bubbleSize = CGSize(width: max(90, min(360, textSize.width + padding * 2)),
                                height: max(38, textSize.height + padding * 1.55))
        return CGRect(origin: clampBubbleOrigin(anchor, size: bubbleSize), size: bubbleSize)
    }

    private func activeCalloutBubble(text: String, pending: PendingTextAnnotation) -> CGRect {
        let anchor = pending.calloutBubble?.origin ?? pending.end
        return calloutTextRect(text: text, anchor: anchor, width: pending.width)
    }

    private func calloutRect(for annotation: Annotation, text: String) -> CGRect {
        annotation.calloutBubble ?? calloutTextRect(text: text, anchor: annotation.end, width: annotation.width)
    }

    private func clampBubbleOrigin(_ origin: CGPoint, size: CGSize) -> CGPoint {
        let margin: CGFloat = 6
        return CGPoint(x: min(max(margin, origin.x), max(margin, bounds.width - size.width - margin)),
                       y: min(max(margin, origin.y), max(margin, bounds.height - size.height - margin)))
    }

    private func calloutEditorFrame(in bubble: CGRect, width: CGFloat) -> CGRect {
        let padding = max(10, textFontSize(width: width) * 0.42)
        return bubble.insetBy(dx: padding, dy: max(6, padding * 0.35))
    }

    private func drawCallout(text: String, head: CGPoint, bubbleAnchor: CGPoint,
                             color: NSColor, width: CGFloat, bubble: CGRect? = nil,
                             alpha: CGFloat = 1, drawsText: Bool = true) {
        let displayText = text.isEmpty ? loc("Callout text", "말풍선 텍스트") : text
        let bubble = bubble ?? calloutTextRect(text: displayText, anchor: bubbleAnchor, width: width)
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
            drawText(displayText, at: textPoint, color: color, width: width, alpha: alpha, halo: false)
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

    private func drawMiddleCutOverlay(_ rect: CGRect) {
        guard !rect.isEmpty else { return }
        Brand.red.withAlphaComponent(0.32).setFill()
        rect.fill()

        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2 / zoomScale
        border.setLineDash([7 / zoomScale, 5 / zoomScale], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        border.stroke()
    }

    /// 알파가 있는 구간을 편집 화면에서 알아볼 수 있게 하는 체크무늬. 결과 PNG에는 포함되지 않는다.
    private static let transparencyPattern: NSColor = {
        let tile = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor(white: 0.88, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.78, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: 8, height: 8).fill()
            CGRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: tile)
    }()

    // MARK: 유틸
    private func distanceFromPoint(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func ellipseHit(_ point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> Bool {
        let expanded = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard expanded.width > 0, expanded.height > 0 else { return false }
        let rx = expanded.width / 2
        let ry = expanded.height / 2
        guard rx > 0, ry > 0 else { return false }
        let nx = (point.x - expanded.midX) / rx
        let ny = (point.y - expanded.midY) / ry
        return nx * nx + ny * ny <= 1
    }

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
