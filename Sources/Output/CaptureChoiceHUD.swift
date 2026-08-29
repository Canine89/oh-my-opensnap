import AppKit

/// 선택 영역 아래 붙는 작은 툴바: 이미지(⏎) / 영상(R). Esc·우클릭은 취소.
/// 질문 문장과 취소 버튼 없이, 키보드만으로 결정할 수 있게 한다.
@MainActor
final class CaptureChoiceHUD {
    private static let captureDismissalDelay: TimeInterval = 0.18

    private let panel: CaptureChoicePanel
    private let onImage: () -> Void
    private let onVideo: () -> Void
    private let onCancel: () -> Void
    private var decided = false

    init(anchor: CGRect,
         onImage: @escaping () -> Void,
         onVideo: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.onImage = onImage
        self.onVideo = onVideo
        self.onCancel = onCancel

        let size = NSSize(width: 292, height: 54)
        let frame = Self.frame(size: size, near: anchor)
        panel = CaptureChoicePanel(contentRect: frame,
                                   styleMask: [.borderless],
                                   backing: .buffered,
                                   defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.sharingType = .none
        // 오버레이(.screenSaver)와 같은 레벨이면 영역 조정 클릭으로 오버레이 창이
        // 앞으로 올라올 때 HUD가 뒤로 숨는다 → 한 단계 높은 레벨로 항상 위에 둔다.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }

        buildContent(size: size)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        panel.alphaValue = 0
        panel.hasShadow = false
        panel.contentView?.isHidden = true
        panel.displayIfNeeded()
        panel.orderOut(nil)
    }

    /// 선택 영역이 조정되면 HUD를 새 영역 근처로 옮긴다.
    func move(near anchor: CGRect) {
        panel.setFrame(Self.frame(size: panel.frame.size, near: anchor), display: true)
    }

    /// HUD가 key가 아니어도(오버레이를 클릭해 조정 중) 키로 결정할 수 있게, 컨트롤러의
    /// 키 모니터가 먼저 이 메서드로 넘긴다. 처리했으면 true.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard !decided else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 53: cancel(); return true                    // Esc
        case 36, 76: captureImage(); return true          // Return / 키패드 Enter
        default: break
        }
        if event.charactersIgnoringModifiers?.lowercased() == "r" {
            recordVideo()
            return true
        }
        return false
    }

    private func buildContent(size: NSSize) {
        let container = HUDSurfaceView(frame: NSRect(origin: .zero, size: size))

        let imageButton = HUDButton(title: "이미지 캡처", role: .primary, symbol: "camera",
                                    keyHint: "⏎", target: self, action: #selector(captureImage))
        let videoButton = HUDButton(title: "영상 촬영", role: .secondary, symbol: "record.circle",
                                    keyHint: "R", target: self, action: #selector(recordVideo))
        imageButton.toolTip = "선택 영역을 이미지로 캡처 (⏎)"
        videoButton.toolTip = "선택 영역을 영상으로 촬영 (R) · Esc 취소"

        let buttons = NSStackView(views: [imageButton, videoButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 34)
        ])

        panel.contentView = container
    }

    @objc private func captureImage() {
        guard !decided else { return }
        decided = true
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDismissalDelay) { [onImage] in onImage() }
    }

    @objc private func recordVideo() {
        guard !decided else { return }
        decided = true
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDismissalDelay) { [onVideo] in onVideo() }
    }

    @objc private func cancel() {
        guard !decided else { return }
        decided = true
        dismiss()
        onCancel()
    }

    private static func frame(size: NSSize, near anchor: CGRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 12
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
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true {
            super.keyDown(with: event)
        }
    }
}
