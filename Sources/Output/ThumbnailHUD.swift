import AppKit

/// 캡처 직후 우하단에 잠깐 떠오르는 썸네일 HUD. 클릭하거나 일정 시간 후 사라진다.
@MainActor
final class ThumbnailHUD {
    private static var liveHUDs: [ThumbnailHUD] = []

    private let panel: NSPanel

    static func show(_ image: NSImage) {
        let hud = ThumbnailHUD(image: image)
        liveHUDs.append(hud)
        hud.present()
    }

    private init(image: NSImage) {
        let size = NSSize(width: 220, height: 160)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: visible.maxX - size.width - 20,
                           y: visible.minY + 20,
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

        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        container.material = .hudWindow
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        let imageView = NSImageView(frame: container.bounds.insetBy(dx: 10, dy: 10))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = image
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        container.addSubview(imageView)

        panel.contentView = container
    }

    private func present() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            self?.dismiss()
        }
    }

    private func dismiss() {
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
