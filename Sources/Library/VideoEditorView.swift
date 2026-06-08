import AppKit
import AVFoundation
import AVKit

@MainActor
final class VideoEditorView: NSView {
    var onOutputCreated: ((URL) -> Void)?
    var onToast: ((String) -> Void)?

    private let playerView = AVPlayerView()
    private let overlayView = VideoCropOverlayView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let selectAreaButton = NSButton(title: "영역 선택", target: nil, action: nil)
    private let cropButton = NSButton(title: "선택 영역 잘라내기", target: nil, action: nil)
    private let gif30Button = NSButton(title: "GIF 30프레임", target: nil, action: nil)
    private let gif45Button = NSButton(title: "GIF 45프레임", target: nil, action: nil)
    private let resetButton = NSButton(title: "영역 초기화", target: nil, action: nil)

    private var representedURL: URL?

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
        statusLabel.stringValue = "영역 선택을 누른 뒤 드래그"
        overlayView.videoSize = Self.videoSize(url: url)
        overlayView.resetSelection()
        overlayView.isSelecting = false
        updateSelectionControls()
        playerView.player = AVPlayer(url: url)
        playerView.player?.play()
    }

    func stop() {
        playerView.player?.pause()
        playerView.player = nil
        representedURL = nil
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false

        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.onSelectionChanged = { [weak self] hasSelection in
            self?.updateSelectionControls()
        }

        let videoContainer = NSView()
        videoContainer.translatesAutoresizingMaskIntoConstraints = false
        videoContainer.addSubview(playerView)
        videoContainer.addSubview(overlayView)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [selectAreaButton, cropButton, gif30Button, gif45Button, resetButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
        }
        selectAreaButton.action = #selector(beginAreaSelection)
        cropButton.action = #selector(exportCroppedMP4)
        gif30Button.action = #selector(exportGIF30)
        gif45Button.action = #selector(exportGIF45)
        resetButton.action = #selector(resetCrop)
        cropButton.isEnabled = false
        resetButton.isEnabled = false

        let controls = NSStackView(views: [selectAreaButton, cropButton, gif30Button, gif45Button, resetButton, statusLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        controls.translatesAutoresizingMaskIntoConstraints = false

        addSubview(videoContainer)
        addSubview(controls)

        NSLayoutConstraint.activate([
            videoContainer.topAnchor.constraint(equalTo: topAnchor),
            videoContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoContainer.bottomAnchor.constraint(equalTo: controls.topAnchor),

            playerView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),

            overlayView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),

            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: 46)
        ])
    }

    @objc private func resetCrop() {
        overlayView.resetSelection()
        overlayView.isSelecting = false
        updateSelectionControls()
    }

    @objc private func beginAreaSelection() {
        overlayView.isSelecting = true
        statusLabel.stringValue = "영상 위에서 잘라낼 영역을 드래그"
        window?.makeFirstResponder(overlayView)
    }

    @objc private func exportCroppedMP4() {
        guard let url = representedURL, overlayView.hasSelection else {
            onToast?("먼저 영역을 선택하세요")
            return
        }
        setBusy(true, message: "MP4 잘라내는 중...")
        VideoExportService.croppedMP4(source: url, crop: overlayView.exportCropRect) { [weak self] result in
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
        VideoExportService.gif(source: url, crop: overlayView.optionalCropRect, frameCount: frameCount) { [weak self] result in
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

    private func setBusy(_ busy: Bool, message: String) {
        [selectAreaButton, cropButton, gif30Button, gif45Button, resetButton].forEach { $0.isEnabled = !busy }
        if busy {
            statusLabel.stringValue = message
        } else {
            updateSelectionControls()
        }
    }

    private func updateSelectionControls() {
        let hasSelection = overlayView.hasSelection
        selectAreaButton.title = hasSelection ? "영역 다시 선택" : "영역 선택"
        cropButton.isEnabled = hasSelection
        resetButton.isEnabled = hasSelection
        statusLabel.stringValue = overlayView.isSelecting
            ? "영상 위에서 잘라낼 영역을 드래그"
            : (hasSelection ? "선택 영역 기준으로 내보내기" : "영역 선택을 누른 뒤 드래그")
    }

    private static func videoSize(url: URL) -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return CGSize(width: 16, height: 9) }
        let transformed = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        return CGSize(width: max(1, abs(transformed.width)), height: max(1, abs(transformed.height)))
    }
}

private final class VideoCropOverlayView: NSView {
    var onSelectionChanged: ((Bool) -> Void)?
    var videoSize = CGSize(width: 16, height: 9) {
        didSet { needsDisplay = true }
    }
    var isSelecting = false {
        didSet {
            needsDisplay = true
        }
    }

    var hasSelection: Bool { selection != nil }
    var optionalCropRect: CGRect? { normalizedCropRect() }
    var exportCropRect: CGRect { normalizedCropRect() ?? CGRect(x: 0, y: 0, width: 1, height: 1) }

    private var selection: CGRect?
    private var dragStart: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    func resetSelection() {
        selection = nil
        dragStart = nil
        onSelectionChanged?(false)
        needsDisplay = true
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isSelecting ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isSelecting else { return }
        let point = clampToVideo(convert(event.locationInWindow, from: nil))
        dragStart = point
        selection = CGRect(origin: point, size: .zero)
        onSelectionChanged?(false)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        guard let dragStart else { return }
        let point = clampToVideo(convert(event.locationInWindow, from: nil))
        selection = CGRect(x: min(dragStart.x, point.x),
                           y: min(dragStart.y, point.y),
                           width: abs(point.x - dragStart.x),
                           height: abs(point.y - dragStart.y))
        onSelectionChanged?((selection?.width ?? 0) > 6 && (selection?.height ?? 0) > 6)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isSelecting else { return }
        if let rect = selection, rect.width <= 6 || rect.height <= 6 {
            selection = nil
        }
        dragStart = nil
        isSelecting = false
        onSelectionChanged?(selection != nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let videoRect = fittedVideoRect()

        guard let selection else {
            if isSelecting { drawHint(in: videoRect) }
            return
        }

        NSColor.black.withAlphaComponent(0.42).setFill()
        let dimPath = NSBezierPath(rect: videoRect)
        dimPath.append(NSBezierPath(rect: selection))
        dimPath.windingRule = .evenOdd
        dimPath.fill()

        NSColor.systemRed.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 2
        border.stroke()
    }

    private func drawHint(in rect: CGRect) {
        let text = "드래그해서 내보낼 영역 선택"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.86)
        ]
        let size = text.size(withAttributes: attrs)
        let point = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        text.draw(at: point, withAttributes: attrs)
    }

    private func normalizedCropRect() -> CGRect? {
        guard let selection else { return nil }
        let videoRect = fittedVideoRect()
        let clipped = selection.intersection(videoRect)
        guard clipped.width > 6, clipped.height > 6 else { return nil }
        return CGRect(x: (clipped.minX - videoRect.minX) / videoRect.width,
                      y: (clipped.minY - videoRect.minY) / videoRect.height,
                      width: clipped.width / videoRect.width,
                      height: clipped.height / videoRect.height)
    }

    private func clampToVideo(_ point: CGPoint) -> CGPoint {
        let rect = fittedVideoRect()
        return CGPoint(x: min(max(point.x, rect.minX), rect.maxX),
                       y: min(max(point.y, rect.minY), rect.maxY))
    }

    private func fittedVideoRect() -> CGRect {
        guard bounds.width > 0, bounds.height > 0, videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let width = videoSize.width * scale
        let height = videoSize.height * scale
        return CGRect(x: bounds.midX - width / 2,
                      y: bounds.midY - height / 2,
                      width: width,
                      height: height)
    }
}
