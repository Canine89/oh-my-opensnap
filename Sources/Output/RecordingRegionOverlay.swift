import AppKit

@MainActor
final class RecordingRegionOverlay {
    private let panel: NSPanel

    init?(displayID: CGDirectDisplayID, captureRect: CGRect) {
        guard let screen = ScreenGeometry.screen(for: displayID) else { return nil }

        panel = NSPanel(contentRect: screen.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none

        let content = RecordingRegionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                                 captureRect: captureRect.integral)
        panel.contentView = content
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}

private final class RecordingRegionOverlayView: NSView {
    private let effectViews = (0..<4).map { _ in NSVisualEffectView() }
    private let borderView = RecordingRegionBorderView()
    private let captureRect: CGRect

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect, captureRect: CGRect) {
        self.captureRect = captureRect.intersection(NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        for effectView in effectViews {
            effectView.material = .hudWindow
            effectView.blendingMode = .behindWindow
            effectView.state = .active
            effectView.alphaValue = 0.92
            effectView.wantsLayer = true
            effectView.layer?.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.34).cgColor
            addSubview(effectView)
        }

        borderView.captureRect = self.captureRect
        borderView.frame = bounds
        borderView.autoresizingMask = [.width, .height]
        addSubview(borderView)
    }

    required init?(coder: NSCoder) {
        self.captureRect = .zero
        super.init(coder: coder)
    }

    override func layout() {
        super.layout()
        let top = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: captureRect.minY - bounds.minY)
        let left = NSRect(x: bounds.minX, y: captureRect.minY, width: captureRect.minX - bounds.minX, height: captureRect.height)
        let right = NSRect(x: captureRect.maxX, y: captureRect.minY, width: bounds.maxX - captureRect.maxX, height: captureRect.height)
        let bottom = NSRect(x: bounds.minX, y: captureRect.maxY, width: bounds.width, height: bounds.maxY - captureRect.maxY)

        for (effectView, rect) in zip(effectViews, [top, left, right, bottom]) {
            effectView.frame = rect
            effectView.isHidden = rect.width <= 0 || rect.height <= 0
        }
    }
}

private final class RecordingRegionBorderView: NSView {
    var captureRect: CGRect = .zero

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !captureRect.isEmpty else { return }

        let border = NSBezierPath(rect: captureRect.insetBy(dx: 0.5, dy: 0.5))
        NSColor.white.withAlphaComponent(0.92).setStroke()
        border.lineWidth = 1.5
        border.stroke()

        let accent = NSBezierPath(rect: captureRect.insetBy(dx: 3, dy: 3))
        NSColor.systemRed.withAlphaComponent(0.86).setStroke()
        accent.lineWidth = 2
        accent.stroke()
    }
}
