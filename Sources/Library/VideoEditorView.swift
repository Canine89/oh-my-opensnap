import AppKit
import AVFoundation
import AVKit

@MainActor
final class VideoEditorView: NSView {
    var onOutputCreated: ((URL) -> Void)?
    var onToast: ((String) -> Void)?

    private let playerView = AVPlayerView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let startSlider = NSSlider()
    private let endSlider = NSSlider()
    private let startLabel = NSTextField(labelWithString: "시작 00:00.0")
    private let endLabel = NSTextField(labelWithString: "끝 00:00.0")
    private let setStartButton = NSButton(title: "현재를 시작", target: nil, action: nil)
    private let setEndButton = NSButton(title: "현재를 끝", target: nil, action: nil)
    private let trimButton = NSButton(title: "구간 잘라내기", target: nil, action: nil)
    private let gif30Button = NSButton(title: "GIF 30프레임", target: nil, action: nil)
    private let gif45Button = NSButton(title: "GIF 45프레임", target: nil, action: nil)
    private let resetButton = NSButton(title: "구간 초기화", target: nil, action: nil)

    private var representedURL: URL?
    private var duration: Double = 0
    private var isBusy = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    func load(url: URL) {
        representedURL = url
        duration = max(0, Self.videoDuration(url: url))
        playerView.player = AVPlayer(url: url)
        resetRange()
        playerView.player?.play()
    }

    func stop() {
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

        for slider in [startSlider, endSlider] {
            slider.minValue = 0
            slider.target = self
            slider.action = #selector(rangeSliderChanged(_:))
            slider.translatesAutoresizingMaskIntoConstraints = false
        }

        for label in [startLabel, endLabel, statusLabel] {
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [setStartButton, setEndButton, trimButton, gif30Button, gif45Button, resetButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
        }
        setStartButton.action = #selector(setCurrentAsStart)
        setEndButton.action = #selector(setCurrentAsEnd)
        trimButton.action = #selector(exportTrimmedMP4)
        gif30Button.action = #selector(exportGIF30)
        gif45Button.action = #selector(exportGIF45)
        resetButton.action = #selector(resetRangeAction)

        let startRow = NSStackView(views: [startLabel, startSlider, setStartButton])
        startRow.orientation = .horizontal
        startRow.alignment = .centerY
        startRow.spacing = 8

        let endRow = NSStackView(views: [endLabel, endSlider, setEndButton])
        endRow.orientation = .horizontal
        endRow.alignment = .centerY
        endRow.spacing = 8

        let actionRow = NSStackView(views: [trimButton, gif30Button, gif45Button, resetButton, statusLabel])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let controls = NSStackView(views: [startRow, endRow, actionRow])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        controls.translatesAutoresizingMaskIntoConstraints = false

        addSubview(playerView)
        addSubview(controls)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: controls.topAnchor),

            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: 112),

            startSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            endSlider.widthAnchor.constraint(equalTo: startSlider.widthAnchor),
            startLabel.widthAnchor.constraint(equalToConstant: 86),
            endLabel.widthAnchor.constraint(equalToConstant: 86)
        ])
    }

    @objc private func rangeSliderChanged(_ sender: NSSlider) {
        normalizeRange(changed: sender)
        updateLabels()
    }

    @objc private func setCurrentAsStart() {
        startSlider.doubleValue = currentPlaybackSeconds()
        normalizeRange(changed: startSlider)
        updateLabels()
    }

    @objc private func setCurrentAsEnd() {
        endSlider.doubleValue = currentPlaybackSeconds()
        normalizeRange(changed: endSlider)
        updateLabels()
    }

    @objc private func resetRangeAction() {
        resetRange()
    }

    @objc private func exportTrimmedMP4() {
        guard let url = representedURL else { return }
        let range = selectedRange()
        guard range.duration.seconds > 0.05, range.duration.seconds < max(duration - 0.05, 0) else {
            onToast?("잘라낼 시작/끝 초를 먼저 지정하세요")
            return
        }
        setBusy(true, message: "MP4 구간 잘라내는 중...")
        VideoExportService.trimmedMP4(source: url, timeRange: range) { [weak self] result in
            self?.handleExport(result, successMessage: "잘라낸 MP4 저장됨")
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
        startSlider.maxValue = duration
        endSlider.maxValue = duration
        startSlider.doubleValue = 0
        endSlider.doubleValue = duration
        updateLabels()
    }

    private func normalizeRange(changed slider: NSSlider) {
        let minGap = min(0.1, max(duration, 0) / 10)
        if slider === startSlider, startSlider.doubleValue > endSlider.doubleValue - minGap {
            endSlider.doubleValue = min(duration, startSlider.doubleValue + minGap)
        }
        if slider === endSlider, endSlider.doubleValue < startSlider.doubleValue + minGap {
            startSlider.doubleValue = max(0, endSlider.doubleValue - minGap)
        }
        startSlider.doubleValue = min(max(0, startSlider.doubleValue), duration)
        endSlider.doubleValue = min(max(startSlider.doubleValue + minGap, endSlider.doubleValue), duration)
    }

    private func selectedRange() -> CMTimeRange {
        let start = min(startSlider.doubleValue, endSlider.doubleValue)
        let end = max(startSlider.doubleValue, endSlider.doubleValue)
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                           end: CMTime(seconds: end, preferredTimescale: 600))
    }

    private func currentPlaybackSeconds() -> Double {
        guard let seconds = playerView.player?.currentTime().seconds, seconds.isFinite else { return 0 }
        return min(max(0, seconds), duration)
    }

    private func updateLabels() {
        startLabel.stringValue = "시작 \(formatTime(startSlider.doubleValue))"
        endLabel.stringValue = "끝 \(formatTime(endSlider.doubleValue))"
        let range = selectedRange()
        statusLabel.stringValue = "선택 \(formatTime(range.duration.seconds)) / 전체 \(formatTime(duration))"
    }

    private func setBusy(_ busy: Bool, message: String) {
        isBusy = busy
        [setStartButton, setEndButton, trimButton, gif30Button, gif45Button, resetButton, startSlider, endSlider]
            .forEach { $0.isEnabled = !busy }
        if busy {
            statusLabel.stringValue = message
        } else {
            updateLabels()
        }
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
