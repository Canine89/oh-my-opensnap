import AppKit

@MainActor
final class CaptureChoiceHUD {
    private let panel: CaptureChoicePanel
    private let onImage: () -> Void
    private let onVideo: () -> Void
    private let onCancel: () -> Void

    init(anchor: CGRect,
         onImage: @escaping () -> Void,
         onVideo: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.onImage = onImage
        self.onVideo = onVideo
        self.onCancel = onCancel

        let size = NSSize(width: 318, height: 82)
        let frame = Self.frame(size: size, near: anchor)
        panel = CaptureChoicePanel(contentRect: frame,
                                   styleMask: [.borderless],
                                   backing: .buffered,
                                   defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.cancel() }

        buildContent(size: size)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    /// 선택 영역이 조정되면 HUD를 새 영역 근처로 옮긴다.
    func move(near anchor: CGRect) {
        panel.setFrame(Self.frame(size: panel.frame.size, near: anchor), display: true)
    }

    private func buildContent(size: NSSize) {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.94).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        container.layer?.borderWidth = 1

        let label = NSTextField(labelWithString: "선택한 영역으로 무엇을 할까요?")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let imageButton = makeButton(title: "이미지 캡처", role: .secondary, action: #selector(captureImage))
        let videoButton = makeButton(title: "영상 촬영", role: .primary, action: #selector(recordVideo))
        let cancelButton = makeButton(title: "취소", role: .secondary, action: #selector(cancel))

        let buttons = NSStackView(views: [imageButton, videoButton, cancelButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            buttons.heightAnchor.constraint(equalToConstant: 30)
        ])

        panel.contentView = container
    }

    private func makeButton(title: String, role: HUDButton.Role, action: Selector) -> NSButton {
        HUDButton(title: title, role: role, target: self, action: action)
    }

    @objc private func captureImage() {
        dismiss()
        DispatchQueue.main.async { [onImage] in onImage() }
    }

    @objc private func recordVideo() {
        dismiss()
        DispatchQueue.main.async { [onVideo] in onVideo() }
    }

    @objc private func cancel() {
        dismiss()
        onCancel()
    }

    private static func frame(size: NSSize, near anchor: CGRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 14
        var x = anchor.midX - size.width / 2
        var y = anchor.minY - size.height - gap
        if y < visible.minY + gap {
            y = anchor.maxY + gap
        }
        x = min(max(x, visible.minX + gap), visible.maxX - size.width - gap)
        y = min(max(y, visible.minY + gap), visible.maxY - size.height - gap)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

private final class CaptureChoicePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}
