import AppKit

/// 앱의 모든 떠 있는 HUD(선택 툴바·녹화 표시·썸네일·토스트)가 공유하는 표면.
/// 한 가지 재질(.hudWindow) + 12pt 모서리 + 얇은 테두리로 결을 맞춘다.
final class HUDSurfaceView: NSVisualEffectView {
    /// 배경을 잡고 끌면 창이 따라오게 할지 (녹화 HUD처럼 위치를 옮길 수 있는 경우).
    var movesWindowOnDrag = false
    /// 표면을 클릭했을 때 (드래그가 아닌 짧은 클릭).
    var onClick: (() -> Void)?
    /// 커서가 표면 위에 들어오고 나갈 때.
    var onHoverChanged: ((Bool) -> Void)?

    private var mouseDownPoint: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Brand.cornerRadius
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { movesWindowOnDrag }

    override func resetCursorRects() {
        if movesWindowOnDrag {
            addCursorRect(bounds, cursor: .openHand)
        } else if onClick != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard onHoverChanged != nil else { return }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        if movesWindowOnDrag { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard let onClick, let down = mouseDownPoint else { return }
        let up = convert(event.locationInWindow, from: nil)
        if bounds.contains(up), hypot(up.x - down.x, up.y - down.y) < 4 {
            onClick()
        }
    }
}
