import AppKit

/// 선택 영역 아래 붙는 결정 툴바. 두 행으로 구성한다.
/// - 위 행: 무엇을 잡았는지(앱 아이콘·이름·구역, 또는 "선택 영역")와 픽셀 크기·배율.
/// - 아래 행: 이미지 캡처(⏎) · 영상 촬영(R) · 취소(Esc). 우클릭도 취소.
/// 선택을 조정하면 위치와 크기 표시가 따라 바뀐다.
@MainActor
final class CaptureChoiceHUD {
    /// HUD가 설명하는 대상. 선택이 조정되면 갱신된다.
    struct Context {
        var pixelWidth: Int
        var pixelHeight: Int
        var scale: CGFloat
        var appName: String?
        var appIcon: NSImage?
        /// 창 스냅일 때 "창 전체" / "본문".
        var zone: String?

        static func area(_ rect: CGRect, scale: CGFloat) -> Context {
            Context(pixelWidth: Int((rect.width * scale).rounded()),
                    pixelHeight: Int((rect.height * scale).rounded()),
                    scale: scale,
                    appName: nil,
                    appIcon: nil,
                    zone: nil)
        }

        static func window(_ selection: OverlayView.WindowSelection, scale: CGFloat) -> Context {
            var context = area(selection.rect, scale: scale)
            let app = selection.window.owningApplication
            context.appName = app?.applicationName
            if let pid = app?.processID {
                context.appIcon = NSRunningApplication(processIdentifier: pid)?.icon
            }
            let full = selection.fullRect
            let isFullWindow = abs(selection.rect.width - full.width) < 1
                && abs(selection.rect.height - full.height) < 1
            context.zone = isFullWindow ? loc("Entire window", "창 전체") : loc("Content", "본문")
            return context
        }
    }

    private static let captureDismissalDelay: TimeInterval = 0.18
    private static let minimumWidth: CGFloat = 352

    private let panel: CaptureChoicePanel
    private let onImage: () -> Void
    private let onVideo: () -> Void
    private let onCancel: () -> Void
    private var decided = false

    private let container: HUDSurfaceView
    /// 자동 배치 프레임. 사용자가 끌어 옮기면 그 차이를 `userOffset`으로 기억해 선택 조정 시에도 따라간다.
    private var autoFrame: NSRect = .zero
    private var userOffset: CGPoint?
    private var repositioning = false
    private var moveObserver: NSObjectProtocol?
    private let targetIcon = NSImageView()
    private let targetLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let scaleChip = ChipLabel()

    init(anchor: CGRect,
         context: Context,
         onImage: @escaping () -> Void,
         onVideo: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.onImage = onImage
        self.onVideo = onVideo
        self.onCancel = onCancel

        container = HUDSurfaceView(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: 96))
        panel = CaptureChoicePanel(contentRect: container.frame,
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
        panel.onRightClick = { [weak self] in self?.cancel() }

        // 배경을 잡고 끌면 HUD를 옮길 수 있다 (핸들을 가리거나 보기에 거슬릴 때).
        panel.isMovableByWindowBackground = true
        container.movesWindowOnDrag = true
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                                              object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteUserMove() }
        }

        buildContent()
        apply(context)
        place(near: anchor, display: false)
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    /// 자동 배치(+사용자 오프셋)로 HUD를 옮긴다. 프로그램적 이동은 사용자 드래그로 세지 않는다.
    private func place(near anchor: CGRect, display: Bool) {
        autoFrame = Self.frame(size: fittingSize, near: anchor)
        var target = autoFrame
        if let userOffset {
            target.origin.x += userOffset.x
            target.origin.y += userOffset.y
            target = Self.clamped(target, near: anchor)
        }
        repositioning = true
        panel.setFrame(target, display: display)
        repositioning = false
    }

    /// 사용자가 끌어 옮긴 경우 자동 위치와의 차이를 기억한다.
    private func noteUserMove() {
        guard !repositioning else { return }
        let dx = panel.frame.origin.x - autoFrame.origin.x
        let dy = panel.frame.origin.y - autoFrame.origin.y
        guard abs(dx) > 1 || abs(dy) > 1 else { return }
        userOffset = CGPoint(x: dx, y: dy)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        let target = panel.frame
        panel.setFrame(target.offsetBy(dx: 0, dy: -6), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        repositioning = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.repositioning = false }
        })
    }

    func dismiss() {
        panel.alphaValue = 0
        panel.hasShadow = false
        panel.contentView?.isHidden = true
        panel.displayIfNeeded()
        panel.orderOut(nil)
    }

    /// 선택 영역이 조정되면 HUD를 새 영역 근처로 옮기고 크기 표시를 갱신한다.
    func update(anchor: CGRect, context: Context) {
        apply(context)
        place(near: anchor, display: true)
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

    // MARK: 구성

    private func buildContent() {
        // 위 행 — 대상 · 크기
        targetIcon.imageScaling = .scaleProportionallyUpOrDown
        targetIcon.translatesAutoresizingMaskIntoConstraints = false
        targetIcon.setContentHuggingPriority(.required, for: .horizontal)

        targetLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        targetLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        targetLabel.lineBreakMode = .byTruncatingTail
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        sizeLabel.textColor = .white
        sizeLabel.alignment = .right
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let unitLabel = NSTextField(labelWithString: "px")
        unitLabel.font = .systemFont(ofSize: 11, weight: .medium)
        unitLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        unitLabel.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let info = NSStackView(views: [targetIcon, targetLabel, spacer, sizeLabel, unitLabel, scaleChip])
        info.orientation = .horizontal
        info.alignment = .centerY
        info.spacing = 5
        info.setCustomSpacing(6, after: targetIcon)
        info.setCustomSpacing(3, after: sizeLabel)
        info.setCustomSpacing(7, after: unitLabel)
        info.translatesAutoresizingMaskIntoConstraints = false

        // 구분선
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor

        // 아래 행 — 동작
        let imageButton = HUDButton(title: loc("Capture Image", "이미지 캡처"), role: .primary, symbol: "camera.fill",
                                    keyHint: "⏎", target: self, action: #selector(captureImage))
        let videoButton = HUDButton(title: loc("Record Video", "영상 촬영"), role: .secondary, symbol: "record.circle",
                                    keyHint: "R", target: self, action: #selector(recordVideo))
        let cancelButton = HUDButton(title: loc("Cancel", "취소"), role: .tertiary, symbol: nil,
                                     keyHint: "Esc", target: self, action: #selector(cancel))
        imageButton.toolTip = loc("Capture the selection as an image and copy it to the clipboard (⏎)", "선택 영역을 이미지로 캡처하고 클립보드에 복사 (⏎)")
        videoButton.toolTip = loc("Record the selection as a video (R)", "선택 영역을 영상으로 촬영 (R)")
        cancelButton.toolTip = loc("Cancel capture (Esc · right-click)", "캡처 취소 (Esc · 우클릭)")
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)

        let actions = NSStackView(views: [imageButton, videoButton, cancelButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.setCustomSpacing(6, after: videoButton)
        actions.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(info)
        container.addSubview(divider)
        container.addSubview(actions)

        let padX: CGFloat = 12
        NSLayoutConstraint.activate([
            targetIcon.widthAnchor.constraint(equalToConstant: 16),
            targetIcon.heightAnchor.constraint(equalToConstant: 16),

            info.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            info.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padX + 2),
            info.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -(padX + 2)),
            info.heightAnchor.constraint(equalToConstant: 18),

            divider.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 9),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padX),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padX),
            divider.heightAnchor.constraint(equalToConstant: 1),

            actions.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            actions.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padX),
            actions.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padX),
            actions.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            imageButton.widthAnchor.constraint(equalTo: videoButton.widthAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth)
        ])

        panel.contentView = container
    }

    private func apply(_ context: Context) {
        if let appName = context.appName, !appName.isEmpty {
            targetLabel.stringValue = context.zone.map { "\(appName) · \($0)" } ?? appName
        } else {
            targetLabel.stringValue = loc("Selected area", "선택 영역")
        }
        if let icon = context.appIcon {
            targetIcon.image = icon
            targetIcon.contentTintColor = nil
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            targetIcon.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: loc("Selected area", "선택 영역"))?
                .withSymbolConfiguration(config)
            targetIcon.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        }
        sizeLabel.stringValue = "\(context.pixelWidth) × \(context.pixelHeight)"
        let scaleText = context.scale == context.scale.rounded()
            ? "\(Int(context.scale))×"
            : String(format: "%.1f×", context.scale)
        scaleChip.text = scaleText
        scaleChip.isHidden = context.scale <= 1
        scaleChip.toolTip = loc("Display scale \(scaleText) — saved at \(scaleText) the displayed size in pixels", "화면 배율 \(scaleText) — 표시 크기의 \(scaleText) 픽셀로 저장")
    }

    private var fittingSize: NSSize {
        container.layoutSubtreeIfNeeded()
        let size = container.fittingSize
        return NSSize(width: max(Self.minimumWidth, ceil(size.width)), height: ceil(size.height))
    }

    // MARK: 동작

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

    private static func visibleFrame(near anchor: CGRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// 화면 밖으로 나가지 않게 가둔다 (사용자 오프셋을 적용한 뒤 다른 디스플레이/크기에서 재배치될 때).
    private static func clamped(_ frame: NSRect, near anchor: CGRect) -> NSRect {
        let visible = visibleFrame(near: anchor)
        let gap: CGFloat = 12
        var f = frame
        f.origin.x = min(max(f.origin.x, visible.minX + gap), visible.maxX - f.width - gap)
        f.origin.y = min(max(f.origin.y, visible.minY + gap), visible.maxY - f.height - gap)
        return f
    }

    private static func frame(size: NSSize, near anchor: CGRect) -> NSRect {
        let visible = visibleFrame(near: anchor)
        let gap: CGFloat = 12
        var x = anchor.midX - size.width / 2
        let below = anchor.minY - size.height - gap
        let above = anchor.maxY + gap
        var y: CGFloat
        if below >= visible.minY + gap {
            y = below
        } else if above + size.height <= visible.maxY - gap {
            y = above
        } else {
            // 위아래 모두 자리가 없으면(거의 전체 화면 선택) 화면 가장자리로 밀어 넣지 않고
            // 영역 안쪽 아래에 띄운다. 가장자리로 밀면 위쪽 핸들을 정확히 덮어 크기 조절이 막힌다.
            // 아래 변 핸들(히트 반경 12pt)도 가리지 않도록 넉넉히 띄운다.
            let handleClearance: CGFloat = 40
            y = anchor.minY + handleClearance
        }
        x = min(max(x, visible.minX + gap), visible.maxX - size.width - gap)
        y = min(max(y, visible.minY + gap), visible.maxY - size.height - gap)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    #if DEBUG
    /// 개발용: HUD 창을 PNG로 저장한다 (`-SnapshotChoiceHUDTo`).
    func debugSnapshot(to path: String) async {
        panel.sharingType = .readOnly            // 평소엔 캡처에서 제외되므로 스냅샷 동안만 허용
        await DebugSnapshot.write(window: panel, to: path)
        panel.sharingType = .none
    }
    #endif
}

/// "2×" 같은 짧은 값을 담는 작은 알약. 버튼 키캡과 같은 결.
private final class ChipLabel: NSView {
    var text: String = "" {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var allowsVibrancy: Bool { false }

    override var intrinsicContentSize: NSSize {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: max(17, ceil(width) + 10), height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4.5, yRadius: 4.5).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                withAttributes: attributes)
    }
}

private final class CaptureChoicePanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onRightClick: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}
