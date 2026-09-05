import AppKit

final class ZoomableScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }

    /// '맞춤' 상태인지. 수동 줌을 하면 해제되고, 그동안은 창 크기에 따라 다시 맞춘다.
    private(set) var isFitMode = true

    func configure() {
        contentView = CenteringClipView()      // 이미지가 뷰보다 작으면 가운데 정렬
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 16
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let dy = event.scrollingDeltaY
        guard dy != 0, let document = documentView else { return }   // 0 델타(관성 꼬리)는 무시
        isFitMode = false
        // 배율을 먼저 [min,max]로 클램프해 둔다(시스템 클램프 후 앵커가 튀는 것 방지).
        let newMag = max(minMagnification, min(magnification * exp(dy * 0.01), maxMagnification))
        setMagnification(newMag, centeredAt: zoomAnchor(for: newMag, document: document, event: event))
    }

    /// 확대 후 이미지가 뷰보다 작으면 '중앙' 기준(센터링과 충돌해 떨리는 것 방지),
    /// 뷰보다 크면 '커서' 기준으로 줌한다.
    private func zoomAnchor(for mag: CGFloat, document: NSView, event: NSEvent) -> CGPoint {
        let scaledW = document.bounds.width * mag
        let scaledH = document.bounds.height * mag
        if scaledW <= contentView.frame.width && scaledH <= contentView.frame.height {
            return CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        }
        return contentView.convert(event.locationInWindow, from: nil)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoomBy(1.25)
        case "-", "_": zoomBy(0.8)
        case "0":      zoomToFit()
        default:       super.keyDown(with: event)
        }
    }

    func zoomBy(_ factor: CGFloat) {
        isFitMode = false
        let center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(magnification * factor, centeredAt: center)
    }

    /// 창 크기는 그대로 두고, 이미지가 미리보기 영역을 채우도록 배율을 맞춘다.
    /// 큰 캡처는 축소하고 작은 캡처는 확대해 → 캡처 크기와 무관하게 일관된 크기로 보인다.
    func zoomToFit() {
        isFitMode = true
        guard let document = documentView, document.bounds.width > 0, document.bounds.height > 0 else { return }
        // 가용 영역은 클립뷰의 '프레임'(화면 point) — 배율과 무관해 반복 호출에도 결과가 안정적이다.
        // (bounds.size 는 현재 배율로 스케일된 값이라, 그걸 쓰면 호출할 때마다 값이 진동한다.)
        // 가장자리에 여백을 둬서 크롭 꼭지점 핸들을 잡기 편하게 한다.
        let inset: CGFloat = 36
        let available = CGSize(width: max(1, contentView.frame.width - inset * 2),
                               height: max(1, contentView.frame.height - inset * 2))
        let fit = min(available.width / document.bounds.width,
                      available.height / document.bounds.height)
        magnification = max(minMagnification, min(fit, maxMagnification))
    }

    /// 창 크기가 바뀌었을 때 '맞춤' 상태면 다시 맞춘다.
    func refitIfNeeded() {
        if isFitMode { zoomToFit() }
    }
}

/// documentView가 클립뷰보다 작을 때 가운데로 정렬한다.
final class CenteringClipView: NSClipView {
    /// 이미지 바깥 여백을 클릭했을 때(=문서뷰 밖, 클립뷰 안), 크롭 중이면 그 클릭을
    /// 문서뷰(에디터)로 넘긴다. 에디터는 좌표를 가장자리로 clamp 해 가까운 크롭 핸들을 잡는다.
    /// → 핸들이 뷰 경계에 걸려 "눌렀는데 안 잡히던" 문제를 해결.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self, let editor = documentView as? EditorImageView, editor.wantsMarginClicks {
            return editor
        }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        if let editor = documentView as? EditorImageView {
            editor.cancelSelectionAndToolFromMarginClick()
        }
        super.mouseDown(with: event)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let docFrame = documentView.frame
        if rect.size.width >= docFrame.size.width {
            rect.origin.x = floor((docFrame.size.width - rect.size.width) / 2.0)
        }
        if rect.size.height >= docFrame.size.height {
            rect.origin.y = floor((docFrame.size.height - rect.size.height) / 2.0)
        }
        return rect
    }
}

