import AppKit
import AVFoundation
import AVKit

@MainActor
final class VideoEditorView: NSView {
    var onOutputCreated: ((URL) -> Void)?
    var onToast: ((String) -> Void)?

    private let playerView = AVPlayerView()
    private let timelineView = TrimTimelineView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let startLabel = NSTextField(labelWithString: "00:00.0")
    private let endLabel = NSTextField(labelWithString: "00:00.0")
    private let playButton = NSButton(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "재생") ?? NSImage(),
                                      target: nil,
                                      action: nil)
    private let backButton = NSButton(image: NSImage(systemSymbolName: "gobackward.5", accessibilityDescription: "5초 뒤로") ?? NSImage(),
                                      target: nil,
                                      action: nil)
    private let forwardButton = NSButton(image: NSImage(systemSymbolName: "goforward.5", accessibilityDescription: "5초 앞으로") ?? NSImage(),
                                         target: nil,
                                         action: nil)
    private let setStartButton = NSButton(title: "현재를 시작", target: nil, action: nil)
    private let setEndButton = NSButton(title: "현재를 끝", target: nil, action: nil)
    private let trimButton = NSButton(title: "선택 구간 MP4 저장", target: nil, action: nil)
    private let gif30Button = NSButton(title: "GIF 30", target: nil, action: nil)
    private let gif45Button = NSButton(title: "GIF 45", target: nil, action: nil)
    private let resetButton = NSButton(title: "초기화", target: nil, action: nil)

    private var representedURL: URL?
    private var duration: Double = 0
    private var isBusy = false
    private var timeObserver: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    func load(url: URL) {
        removeTimeObserver()
        representedURL = url
        duration = max(0, Self.videoDuration(url: url))
        timelineView.configure(duration: duration)
        playerView.player = AVPlayer(url: url)
        installTimeObserver()
        resetRange()
        updatePlayButton()
        playerView.player?.play()
    }

    func stop() {
        removeTimeObserver()
        playerView.player?.pause()
        playerView.player = nil
        representedURL = nil
        duration = 0
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false

        timelineView.translatesAutoresizingMaskIntoConstraints = false
        timelineView.onRangeChanged = { [weak self] in self?.updateLabels() }
        timelineView.onSeekRequested = { [weak self] seconds in self?.seek(to: seconds) }

        for label in [startLabel, endLabel] {
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.alignment = .center
            label.widthAnchor.constraint(equalToConstant: 54).isActive = true
        }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [playButton, backButton, forwardButton, setStartButton, setEndButton, trimButton, gif30Button, gif45Button, resetButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
        }
        playButton.bezelStyle = .texturedRounded
        playButton.controlSize = .large
        playButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        playButton.heightAnchor.constraint(equalToConstant: 34).isActive = true

        playButton.action = #selector(togglePlay)
        backButton.action = #selector(skipBackward)
        forwardButton.action = #selector(skipForward)
        setStartButton.action = #selector(setCurrentAsStart)
        setEndButton.action = #selector(setCurrentAsEnd)
        trimButton.action = #selector(exportTrimmedMP4)
        gif30Button.action = #selector(exportGIF30)
        gif45Button.action = #selector(exportGIF45)
        resetButton.action = #selector(resetRangeAction)

        let panel = NSVisualEffectView()
        panel.material = .hudWindow
        panel.state = .active
        panel.blendingMode = .behindWindow
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false

        let timelineRow = NSStackView(views: [startLabel, timelineView, endLabel])
        timelineRow.orientation = .horizontal
        timelineRow.alignment = .centerY
        timelineRow.spacing = 8
        timelineRow.translatesAutoresizingMaskIntoConstraints = false

        let transportRow = NSStackView(views: [
            setStartButton,
            backButton,
            playButton,
            forwardButton,
            setEndButton,
            NSView(),
            trimButton,
            gif30Button,
            gif45Button,
            resetButton
        ])
        transportRow.orientation = .horizontal
        transportRow.alignment = .centerY
        transportRow.spacing = 8
        transportRow.translatesAutoresizingMaskIntoConstraints = false
        transportRow.setHuggingPriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [timelineRow, transportRow, statusLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)

        addSubview(playerView)
        addSubview(panel)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -12),

            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            panel.heightAnchor.constraint(equalToConstant: 126),

            content.topAnchor.constraint(equalTo: panel.topAnchor),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            timelineRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            timelineRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            timelineView.heightAnchor.constraint(equalToConstant: 30),

            transportRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            transportRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14)
        ])
    }

    @objc private func togglePlay() {
        guard let player = playerView.player else { return }
        if player.rate == 0 {
            player.play()
        } else {
            player.pause()
        }
        updatePlayButton()
    }

    @objc private func skipBackward() {
        seek(to: currentPlaybackSeconds() - 5)
    }

    @objc private func skipForward() {
        seek(to: currentPlaybackSeconds() + 5)
    }

    @objc private func setCurrentAsStart() {
        timelineView.setStart(currentPlaybackSeconds())
        updateLabels()
    }

    @objc private func setCurrentAsEnd() {
        timelineView.setEnd(currentPlaybackSeconds())
        updateLabels()
    }

    @objc private func resetRangeAction() {
        resetRange()
    }

    @objc private func exportTrimmedMP4() {
        guard let url = representedURL else { return }
        let range = selectedRange()
        guard range.duration.seconds > 0.05, range.duration.seconds < max(duration - 0.05, 0) else {
            onToast?("저장할 시작/끝 초를 먼저 지정하세요")
            return
        }
        setBusy(true, message: "선택 구간 MP4 저장 중...")
        VideoExportService.trimmedMP4(source: url, timeRange: range) { [weak self] result in
            self?.handleExport(result, successMessage: "선택 구간 MP4 저장됨")
        }
    }

    @objc private func exportGIF30() {
        exportGIF(frameCount: 30)
    }

    @objc private func exportGIF45() {
        exportGIF(frameCount: 45)
    }

    private func exportGIF(frameCount: Int) {
        guard let url = representedURL else { return }
        setBusy(true, message: "GIF \(frameCount)프레임 내보내는 중...")
        VideoExportService.gif(source: url, timeRange: selectedRange(), frameCount: frameCount) { [weak self] result in
            self?.handleExport(result, successMessage: "GIF \(frameCount)프레임 저장됨")
        }
    }

    private func handleExport(_ result: Result<URL, Error>, successMessage: String) {
        setBusy(false, message: "")
        switch result {
        case .success(let url):
            onToast?(successMessage)
            onOutputCreated?(url)
        case .failure(let error):
            onToast?(error.localizedDescription)
        }
    }

    private func resetRange() {
        timelineView.setRange(start: 0, end: duration)
        seek(to: 0)
        updateLabels()
    }

    private func selectedRange() -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: timelineView.startTime, preferredTimescale: 600),
                    end: CMTime(seconds: timelineView.endTime, preferredTimescale: 600))
    }

    private func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration)
        playerView.player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        timelineView.currentTime = clamped
    }

    private func currentPlaybackSeconds() -> Double {
        guard let seconds = playerView.player?.currentTime().seconds, seconds.isFinite else { return 0 }
        return min(max(0, seconds), duration)
    }

    private func updateLabels() {
        startLabel.stringValue = formatTime(timelineView.startTime)
        endLabel.stringValue = formatTime(timelineView.endTime)
        let range = selectedRange()
        statusLabel.stringValue = "선택 구간 \(formatTime(range.duration.seconds)) / 전체 \(formatTime(duration))"
    }

    private func setBusy(_ busy: Bool, message: String) {
        isBusy = busy
        [setStartButton, setEndButton, trimButton, gif30Button, gif45Button, resetButton, playButton, backButton, forwardButton]
            .forEach { $0.isEnabled = !busy }
        timelineView.isEnabled = !busy
        if busy {
            statusLabel.stringValue = message
        } else {
            updateLabels()
        }
    }

    private func installTimeObserver() {
        guard let player = playerView.player else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.timelineView.currentTime = min(max(0, time.seconds), self.duration)
                self.updatePlayButton()
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver, let player = playerView.player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func updatePlayButton() {
        let symbol = (playerView.player?.rate ?? 0) == 0 ? "play.fill" : "pause.fill"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00.0" }
        let whole = Int(seconds)
        let minutes = whole / 60
        let secs = whole % 60
        let tenths = Int((seconds - Double(whole)) * 10)
        return String(format: "%02d:%02d.%d", minutes, secs, tenths)
    }

    private static func videoDuration(url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let seconds = asset.duration.seconds
        return seconds.isFinite ? seconds : 0
    }
}

private final class TrimTimelineView: NSView {
    var onRangeChanged: (() -> Void)?
    var onSeekRequested: ((Double) -> Void)?
    var startTime: Double = 0
    var endTime: Double = 0
    var currentTime: Double = 0 {
        didSet { needsDisplay = true }
    }
    var isEnabled = true {
        didSet { needsDisplay = true }
    }

    private var duration: Double = 0
    private var activeHandle: Handle?
    private enum Handle { case start, end, playhead }

    override var acceptsFirstResponder: Bool { true }

    func configure(duration: Double) {
        self.duration = max(0, duration)
        setRange(start: 0, end: duration)
    }

    func setRange(start: Double, end: Double) {
        startTime = clamp(start)
        endTime = max(startTime, clamp(end))
        currentTime = clamp(currentTime)
        onRangeChanged?()
        needsDisplay = true
    }

    func setStart(_ seconds: Double) {
        startTime = min(clamp(seconds), max(0, endTime - minimumGap))
        onRangeChanged?()
        needsDisplay = true
    }

    func setEnd(_ seconds: Double) {
        endTime = max(clamp(seconds), min(duration, startTime + minimumGap))
        onRangeChanged?()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, duration > 0 else { return }
        window?.makeFirstResponder(self)
        let x = convert(event.locationInWindow, from: nil).x
        activeHandle = nearestHandle(to: x)
        update(handle: activeHandle, x: x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let activeHandle else { return }
        update(handle: activeHandle, x: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        activeHandle = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = trackRect
        NSColor.controlBackgroundColor.setFill()
        rounded(track, radius: 5).fill()

        let selected = CGRect(x: x(for: startTime),
                              y: track.minY,
                              width: max(2, x(for: endTime) - x(for: startTime)),
                              height: track.height)
        NSColor.systemBlue.withAlphaComponent(isEnabled ? 0.34 : 0.14).setFill()
        rounded(selected, radius: 5).fill()

        drawTickMarks(in: track)
        drawHandle(x: x(for: startTime), color: .systemGreen, label: "시작")
        drawHandle(x: x(for: endTime), color: .systemRed, label: "끝")
        drawPlayhead(x: x(for: currentTime))
    }

    private func drawTickMarks(in track: CGRect) {
        guard duration > 0 else { return }
        NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath()
        let count = 8
        for index in 0...count {
            let x = track.minX + track.width * CGFloat(index) / CGFloat(count)
            path.move(to: CGPoint(x: x, y: track.minY + 4))
            path.line(to: CGPoint(x: x, y: track.maxY - 4))
        }
        path.lineWidth = 1
        path.stroke()
    }

    private func drawHandle(x: CGFloat, color: NSColor, label: String) {
        let rect = CGRect(x: x - 5, y: trackRect.minY - 5, width: 10, height: trackRect.height + 10)
        color.setFill()
        rounded(rect, radius: 3).fill()
        NSColor.white.withAlphaComponent(0.95).setFill()
        CGRect(x: x - 1, y: rect.minY + 4, width: 2, height: rect.height - 8).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: color
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: CGPoint(x: x - size.width / 2, y: rect.minY - 13), withAttributes: attrs)
    }

    private func drawPlayhead(x: CGFloat) {
        NSColor.labelColor.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: x, y: trackRect.minY - 7))
        path.line(to: CGPoint(x: x, y: trackRect.maxY + 7))
        path.lineWidth = 1.5
        path.stroke()
    }

    private func rounded(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    private func nearestHandle(to x: CGFloat) -> Handle {
        let positions: [(Handle, CGFloat)] = [(.start, self.x(for: startTime)),
                                              (.end, self.x(for: endTime)),
                                              (.playhead, self.x(for: currentTime))]
        return positions.min { abs($0.1 - x) < abs($1.1 - x) }?.0 ?? .playhead
    }

    private func update(handle: Handle?, x: CGFloat) {
        let time = time(for: x)
        switch handle {
        case .start:
            setStart(time)
        case .end:
            setEnd(time)
        case .playhead, .none:
            currentTime = clamp(time)
            onSeekRequested?(currentTime)
        }
    }

    private var trackRect: CGRect {
        bounds.insetBy(dx: 10, dy: 10)
    }

    private var minimumGap: Double {
        min(0.1, max(duration, 0) / 10)
    }

    private func x(for seconds: Double) -> CGFloat {
        let track = trackRect
        guard duration > 0 else { return track.minX }
        return track.minX + track.width * CGFloat(clamp(seconds) / duration)
    }

    private func time(for x: CGFloat) -> Double {
        let track = trackRect
        guard duration > 0, track.width > 0 else { return 0 }
        let progress = min(max(0, (x - track.minX) / track.width), 1)
        return Double(progress) * duration
    }

    private func clamp(_ seconds: Double) -> Double {
        min(max(0, seconds.isFinite ? seconds : 0), duration)
    }
}
