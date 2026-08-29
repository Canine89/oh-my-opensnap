import AppKit

/// 캡처 직후 우하단에 잠깐 떠오르는 썸네일 HUD.
/// 연속 캡처는 위로 쌓이고, 커서를 올리면 사라지지 않으며, 클릭하면 라이브러리에서 연다.
@MainActor
final class ThumbnailHUD {
    private static var liveHUDs: [ThumbnailHUD] = []
    private static let size = NSSize(width: 232, height: 176)
    private static let margin: CGFloat = 20
    private static let gap: CGFloat = 10

    private let panel: NSPanel
    private var dismissWork: DispatchWorkItem?
    private var dismissed = false

    static func show(_ image: NSImage) {
        let hud = ThumbnailHUD(image: image, stackIndex: liveHUDs.count)
        liveHUDs.append(hud)
        hud.present()
    }

    private init(image: NSImage, stackIndex: Int) {
        let size = Self.size
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: visible.maxX - size.width - Self.margin,
                           y: visible.minY + Self.margin + CGFloat(stackIndex) * (size.height + Self.gap),
                           width: size.width, height: size.height)

        panel = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = HUDSurfaceView(frame: NSRect(origin: .zero, size: size))
        container.onClick = { [weak self] in
            LibraryWindowController.shared.showWindowSelectingLatest()
            self?.dismiss()
        }
        container.onHoverChanged = { [weak self] hovering in
            // 보고 있는 동안은 사라지지 않고, 커서가 떠나면 짧게 뒤 사라진다.
            if hovering { self?.cancelScheduledDismiss() } else { self?.scheduleDismiss(after: 1.2) }
        }

        let imageView = NSImageView(frame: NSRect(x: 10, y: 32, width: size.width - 20, height: size.height - 42))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = image
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Brand.innerCornerRadius
        imageView.layer?.masksToBounds = true
        container.addSubview(imageView)

        let label = NSTextField(labelWithString: "클립보드에 복사됨 · 클릭하면 라이브러리")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 12, y: 10, width: size.width - 24, height: 14)
        label.alignment = .left
        container.addSubview(label)

        panel.contentView = container
    }

    private func present() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        scheduleDismiss(after: 3.5)
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        cancelScheduledDismiss()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelScheduledDismiss() {
        dismissWork?.cancel()
        dismissWork = nil
    }

    private func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        cancelScheduledDismiss()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            ThumbnailHUD.liveHUDs.removeAll { $0 === self }
        })
    }
}
