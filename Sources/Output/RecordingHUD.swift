import AppKit

@MainActor
final class RecordingHUD {
    private let panel: RecordingPanel
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let statusLabel = NSTextField(labelWithString: "촬영 중")
    private let pauseButton = NSButton(title: "일시정지", target: nil, action: nil)
    private let stopButton = NSButton(title: "중지", target: nil, action: nil)
    private let onPauseToggle: () -> Void
    private let onStop: () -> Void

    private var timer: Timer?
    private var startedAt = Date()
    private var pausedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var isPaused = false

    init(onPauseToggle: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onPauseToggle = onPauseToggle
        self.onStop = onStop

        let size = NSSize(width: 330, height: 58)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: visible.midX - size.width / 2,
                           y: visible.minY + 22,
                           width: size.width,
                           height: size.height)

        panel = RecordingPanel(contentRect: frame,
                               styleMask: [.borderless],
                               backing: .buffered,
                               defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none

        buildContent(size: size)
    }

    func show() {
        startedAt = Date()
        pausedAt = nil
        pausedDuration = 0
        updateTime()
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateTime()
            }
        }
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            pausedAt = Date()
            statusLabel.stringValue = "일시정지"
            pauseButton.title = "재개"
        } else {
            if let pausedAt { pausedDuration += Date().timeIntervalSince(pausedAt) }
            pausedAt = nil
            statusLabel.stringValue = "촬영 중"
            pauseButton.title = "일시정지"
        }
        updateTime()
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func buildContent(size: NSSize) {
        let container = DraggableHUDBackground(frame: NSRect(origin: .zero, size: size))
        container.material = .hudWindow
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.alignment = .right
        timeLabel.widthAnchor.constraint(equalToConstant: 54).isActive = true

        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.bezelStyle = .rounded

        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.bezelStyle = .rounded
        stopButton.contentTintColor = .systemRed

        let stack = NSStackView(views: [dot, statusLabel, timeLabel, pauseButton, stopButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        panel.contentView = container
    }

    private func updateTime() {
        let reference = pausedAt ?? Date()
        let elapsed = max(0, reference.timeIntervalSince(startedAt) - pausedDuration)
        let totalSeconds = Int(elapsed.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        timeLabel.stringValue = String(format: "%02d:%02d", minutes, seconds)
    }

    @objc private func togglePause() {
        onPauseToggle()
    }

    @objc private func stop() {
        onStop()
    }
}

private final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class DraggableHUDBackground: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
