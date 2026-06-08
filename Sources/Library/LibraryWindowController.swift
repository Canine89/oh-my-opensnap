import AppKit
import UniformTypeIdentifiers
import WebKit

/// 캡처 라이브러리 편집/뷰어 창.
/// 레이아웃: 상단 툴바 + 좌측 썸네일 그리드 + 우측 큰 미리보기.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let shared = LibraryWindowController()

    private var window: NSWindow?
    private let collectionView = ThumbnailCollectionView()
    private let previewScroll = ZoomableScrollView()
    private let editorView = EditorImageView()
    private let videoEditorView = VideoEditorView()
    private let animatedImageView = WKWebView()
    private let emptyLabel = NSTextField(labelWithString: "아직 잡아 둔 화면이 없어요.\n⌘⇧2 로 캡처하면 여기에 빨갛게 짚어 둘 수 있습니다.")
    private let countLabel = NSTextField(labelWithString: "")
    private let widthSlider = NSSlider()
    private let widthLabel = NSTextField(labelWithString: "")
    private let cropDoneButton = NSButton(title: "완료", target: nil, action: nil)

    // 편집 도구 (세그먼트 인덱스 → 도구)
    private let tools: [EditorImageView.Tool] = [.none, .crop, .number, .arrow, .rectangle, .ellipse, .mosaic]

    private var items: [LibraryItem] = []
    private var selectedItem: LibraryItem?
    private var keyMonitor: Any?

    /// 캡처 세션 동안 라이브러리 창을 잠시 숨겼는지. 복원 여부 판단에 쓴다.
    private var hiddenForCapture = false

    /// 다음 목록 반영 시 (이전 선택 대신) 가장 최신 항목을 선택할지.
    /// 캡처 직후 새로 저장된 항목을 자동으로 보여주기 위한 1회성 플래그.
    private var selectLatestPending = false

    private let itemIdentifier = NSUserInterfaceItemIdentifier("ThumbnailItem")

    /// 캡처 직후 호출: 창을 (숨겨져 있었다면 다시) 띄우고, 방금 저장된 최신 항목을 선택해 보여준다.
    func showWindowSelectingLatest() {
        selectLatestPending = true
        showWindow()
    }

    func showWindow() {
        if window == nil { buildWindow() }
        installKeyMonitorIfNeeded()
        NotificationCenter.default.removeObserver(self, name: .libraryDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .libraryDidChange, object: nil)
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 캡처 세션 진입 시 호출: 라이브러리 창이 스틸 캡처에 함께 찍히지 않도록 잠시 숨긴다.
    /// (열려 있던 경우에만 숨기고, 그 사실을 기억해 두었다가 세션 종료 후 되돌린다.)
    func hideForCapture() {
        guard let window, window.isVisible else { hiddenForCapture = false; return }
        hiddenForCapture = true
        window.orderOut(nil)
    }

    /// 캡처 세션 종료 후 호출: 진입 전에 열려 있던 라이브러리 창을 원래대로 되돌린다.
    func restoreAfterCapture() {
        guard hiddenForCapture, let window else { return }
        hiddenForCapture = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// ⌘ 단축키(되돌리기/복사/줌)를 라이브러리 창에서 확실히 가로채는 로컬 모니터.
    /// performKeyEquivalent가 스크롤뷰 계층에서 누락되는 경우를 우회한다.
    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isVisible == true,
                  event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z": self.editorView.undo(); return nil
            case "c": self.editorView.copyToClipboard(); return nil
            case "=", "+": self.previewScroll.zoomBy(1.25); return nil
            case "-", "_": self.previewScroll.zoomBy(0.8); return nil
            case "0": self.previewScroll.zoomToFit(); return nil
            default: return event
            }
        }
    }

    // MARK: 구성
    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(Brand.name) — 라이브러리"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 460)
        window.center()
        window.setFrameAutosaveName("LibraryWindowV2")

        let content = NSView()

        // 상단 툴바
        let toolbar = buildToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        // 썸네일 그리드
        let flow = NSCollectionViewFlowLayout()
        flow.itemSize = NSSize(width: 116, height: 96)
        flow.minimumInteritemSpacing = 8
        flow.minimumLineSpacing = 8
        flow.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        collectionView.collectionViewLayout = flow
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: itemIdentifier)
        // 썸네일 우클릭 → "Finder에서 보기" 컨텍스트 메뉴
        collectionView.menuProvider = { [weak self] indexPath in
            guard let self, self.items.indices.contains(indexPath.item) else { return nil }
            self.select(indexPath.item)     // 우클릭한 항목을 선택 + 미리보기로
            let menu = NSMenu()
            let reveal = NSMenuItem(title: "Finder에서 보기", action: #selector(self.revealSelected), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)
            return menu
        }

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // 미리보기 (확대/축소 가능한 스크롤뷰)
        let previewContainer = NSView()
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        previewContainer.translatesAutoresizingMaskIntoConstraints = false

        editorView.onImageChanged = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.previewScroll.zoomToFit()
                self.window?.makeFirstResponder(self.editorView)
            }
        }
        editorView.onCropProgress = { [weak self] progressed in
            self?.cropDoneButton.isHidden = !progressed
        }
        editorView.onDidCopy = { [weak self] in
            self?.showToast("클립보드에 복사됨")
        }
        // 크롭 적용/되돌리기로 이미지가 바뀌면 라이브러리 파일에 반영하고 썸네일만 갱신.
        // (에디터를 reload하지 않으므로 undo 스택이 보존된다 → 크롭도 ⌘Z로 되돌릴 수 있음)
        editorView.onEditCommitted = { [weak self] in
            self?.persistCurrentEdit()
        }
        videoEditorView.onToast = { [weak self] message in
            self?.showToast(message)
        }
        videoEditorView.onOutputCreated = { [weak self] url in
            guard let self else { return }
            self.selectLatestPending = true
            CaptureLibrary.shared.fileDidChange(url)
        }

        previewScroll.configure()
        previewScroll.documentView = editorView
        previewScroll.backgroundColor = .underPageBackgroundColor
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewScroll)

        videoEditorView.translatesAutoresizingMaskIntoConstraints = false
        videoEditorView.isHidden = true
        previewContainer.addSubview(videoEditorView)

        animatedImageView.translatesAutoresizingMaskIntoConstraints = false
        animatedImageView.isHidden = true
        previewContainer.addSubview(animatedImageView)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(emptyLabel)

        // 크롭 진행 시 떠오르는 [완료] 버튼
        cropDoneButton.bezelStyle = .rounded
        cropDoneButton.controlSize = .large
        cropDoneButton.keyEquivalent = "\r"
        cropDoneButton.target = self
        cropDoneButton.action = #selector(commitCrop)
        cropDoneButton.isHidden = true
        cropDoneButton.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) { cropDoneButton.bezelColor = Brand.red }
        previewContainer.addSubview(cropDoneButton)

        content.addSubview(toolbar)
        content.addSubview(scroll)
        content.addSubview(previewContainer)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48),

            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 264),

            previewContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            previewScroll.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewScroll.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

            videoEditorView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            videoEditorView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            videoEditorView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            videoEditorView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

            animatedImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 18),
            animatedImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 18),
            animatedImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -18),
            animatedImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -18),

            emptyLabel.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),

            cropDoneButton.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            cropDoneButton.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -18)
        ])

        window.contentView = content
        self.window = window
    }

    private func buildToolbar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        func iconButton(_ symbol: String, _ action: Selector, _ help: String) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(),
                             target: self, action: action)
            b.bezelStyle = .rounded
            b.toolTip = help
            return b
        }

        // 편집 도구: 포인터 / 크롭 / 번호 / 화살표 / 사각형 / 원
        let toolControl = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        let symbols = ["cursorarrow", "crop", "number.circle", "arrow.up.right", "rectangle", "circle", "square.grid.3x3.fill"]
        let tips = ["선택", "크롭 (드래그 후 ⏎ 적용)", "번호 ➊–➒", "화살표", "사각형", "원", "모자이크 (드래그)"]
        toolControl.segmentCount = symbols.count
        for (i, symbol) in symbols.enumerated() {
            toolControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: tips[i]), forSegment: i)
            toolControl.setToolTip(tips[i], forSegment: i)
            toolControl.setWidth(34, forSegment: i)
        }
        toolControl.selectedSegment = 0

        // 색상 (기본 빨강)
        let colorWell = NSColorWell()
        colorWell.color = Brand.red
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.widthAnchor.constraint(equalToConstant: 38).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true

        // 굵기 (px)
        widthSlider.minValue = 1
        widthSlider.maxValue = 20
        widthSlider.doubleValue = Double(editorView.strokeWidth)
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged(_:))
        widthSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        widthLabel.stringValue = "\(Int(editorView.strokeWidth))px"
        widthLabel.textColor = .secondaryLabelColor
        widthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        stack.addArrangedSubview(toolControl)
        stack.addArrangedSubview(colorWell)
        stack.addArrangedSubview(widthSlider)
        stack.addArrangedSubview(widthLabel)
        stack.addArrangedSubview(iconButton("arrow.uturn.backward", #selector(undoEdit), "되돌리기 (⌘Z)"))
        stack.addArrangedSubview(iconButton("square.and.arrow.down", #selector(saveSelected), "저장"))
        stack.addArrangedSubview(iconButton("folder", #selector(revealSelected), "Finder에서 보기"))
        stack.addArrangedSubview(iconButton("trash", #selector(deleteSelected), "삭제"))

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(stack)
        bar.addSubview(countLabel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            countLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    // MARK: 데이터
    @objc private func reload() {
        // 바탕화면 목록 읽기는 백그라운드에서 (TCC 동의창이 메인을 막지 않도록).
        CaptureLibrary.shared.loadItems { [weak self] items in
            self?.applyItems(items)
        }
    }

    private func applyItems(_ items: [LibraryItem]) {
        self.items = items
        collectionView.reloadData()
        countLabel.stringValue = "\(items.count)개 항목"

        // 캡처 직후: 이전 선택을 무시하고 방금 저장된 최신(0번) 항목을 선택.
        if selectLatestPending, !items.isEmpty {
            selectLatestPending = false
            select(0)
            return
        }

        // 선택 유지 또는 첫 항목 선택
        if let selected = selectedItem, let index = items.firstIndex(where: { $0.url == selected.url }) {
            select(index)
        } else if !items.isEmpty {
            select(0)
        } else {
            selectedItem = nil
            editorView.image = nil
            videoEditorView.stop()
            videoEditorView.isHidden = true
            animatedImageView.loadHTMLString("", baseURL: nil)
            animatedImageView.isHidden = true
            previewScroll.isHidden = false
            emptyLabel.isHidden = false
        }
    }

    private func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [indexPath]
        showPreview(items[index])
    }

    private func showPreview(_ item: LibraryItem) {
        selectedItem = item
        emptyLabel.isHidden = true
        cropDoneButton.isHidden = true
        switch item.kind {
        case .video:
            editorView.image = nil
            animatedImageView.loadHTMLString("", baseURL: nil)
            animatedImageView.isHidden = true
            previewScroll.isHidden = true
            videoEditorView.isHidden = false
            videoEditorView.load(url: item.url)
        case .animatedImage:
            editorView.image = nil
            videoEditorView.stop()
            videoEditorView.isHidden = true
            previewScroll.isHidden = true
            animatedImageView.isHidden = false
            showAnimatedImagePreview(item)
        case .image:
            videoEditorView.stop()
            videoEditorView.isHidden = true
            animatedImageView.loadHTMLString("", baseURL: nil)
            animatedImageView.isHidden = true
            previewScroll.isHidden = false
            showImagePreview(item)
        }
    }

    private func showAnimatedImagePreview(_ item: LibraryItem) {
        animatedImageView.loadFileURL(item.url, allowingReadAccessTo: item.url.deletingLastPathComponent())
    }

    private func showImagePreview(_ item: LibraryItem) {
        // 원본 PNG 읽기는 백그라운드. 그 사이 선택이 바뀌면 결과를 버린다.
        CaptureLibrary.shared.loadImage(at: item.url) { [weak self] image in
            guard let self, self.selectedItem?.url == item.url else { return }
            self.editorView.image = image   // setter가 맞춤/first responder 처리
        }
    }

    // MARK: NSCollectionView
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: itemIdentifier, for: indexPath) as! ThumbnailItem
        let libraryItem = items[indexPath.item]
        // 셀 재사용 대비: 비동기 로드 후 셀이 가리키는 URL이 그대로일 때만 적용.
        item.representedURL = libraryItem.url
        item.thumbnail = nil
        CaptureLibrary.shared.thumbnail(for: libraryItem.url) { image in
            if item.representedURL == libraryItem.url { item.thumbnail = image }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let indexPath = indexPaths.first, items.indices.contains(indexPath.item) {
            showPreview(items[indexPath.item])
        }
    }

    // MARK: 편집 도구 액션
    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard tools.indices.contains(index) else { return }
        editorView.tool = tools[index]
        window?.makeFirstResponder(editorView)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        editorView.strokeColor = sender.color
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        editorView.strokeWidth = CGFloat(sender.doubleValue)
        widthLabel.stringValue = "\(Int(sender.doubleValue))px"
    }

    @objc private func undoEdit() {
        editorView.undo()
    }

    private func showToast(_ message: String) {
        guard let content = window?.contentView else { return }
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0, alpha: 0.82).cgColor
        pill.layer?.cornerRadius = 9
        pill.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        content.addSubview(pill)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -7),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
            pill.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26)
        ])

        pill.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            pill.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                pill.animator().alphaValue = 0
            }, completionHandler: { pill.removeFromSuperview() })
        }
    }

    /// 크롭 적용. 실제 디스크 반영은 editorView.onEditCommitted → persistCurrentEdit()가 맡는다.
    /// (에디터를 reload하지 않아 undo 스택이 살아 있으므로 크롭도 ⌘Z로 되돌릴 수 있다.)
    @objc private func commitCrop() {
        editorView.commitCrop()
        cropDoneButton.isHidden = true
    }

    /// 현재 편집 결과(크롭 등)를 선택된 라이브러리 파일에 덮어쓰고, 해당 썸네일만 갱신한다.
    /// 전체 reload를 하지 않으므로 편집 중인 에디터 상태(undo 스택 포함)는 유지된다.
    private func persistCurrentEdit() {
        guard let item = selectedItem,
              item.url.pathExtension.lowercased() == "png",
              let cg = editorView.renderedCGImage(),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        CaptureLibrary.shared.overwrite(pngData: png, at: item.url) { [weak self] in
            self?.refreshThumbnail(for: item.url)
        }
    }

    /// 그리드에서 해당 URL 셀의 썸네일만 다시 그린다(선택/스크롤 위치 보존).
    private func refreshThumbnail(for url: URL) {
        CaptureLibrary.shared.invalidateThumbnail(for: url)
        guard let index = items.firstIndex(where: { $0.url == url }) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        CaptureLibrary.shared.thumbnail(for: url) { [weak self] image in
            guard let self,
                  let cell = self.collectionView.item(at: indexPath) as? ThumbnailItem,
                  cell.representedURL == url else { return }
            cell.thumbnail = image
        }
    }

    // MARK: 파일 액션
    @objc private func saveSelected() {
        guard let item = selectedItem else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.allowedContentTypes = allowedContentTypes(for: item)
        if panel.runModal() == .OK, let dest = panel.url {
            switch item.kind {
            case .video:
                try? FileManager.default.copyItem(at: item.url, to: dest)
            case .animatedImage:
                try? FileManager.default.copyItem(at: item.url, to: dest)
            case .image:
                guard let cg = editorView.renderedCGImage() else { return }
                let rep = NSBitmapImageRep(cgImage: cg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dest)
                }
            }
        }
    }

    private func allowedContentTypes(for item: LibraryItem) -> [UTType] {
        switch item.url.pathExtension.lowercased() {
        case "mp4": return [.mpeg4Movie]
        case "gif": return [.gif]
        default: return [.png]
        }
    }

    @objc private func revealSelected() {
        guard let item = selectedItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func zoomIn() { previewScroll.zoomBy(1.25) }
    @objc private func zoomOut() { previewScroll.zoomBy(0.8) }
    @objc private func zoomFit() { previewScroll.zoomToFit() }

    @objc private func deleteSelected() {
        guard let item = selectedItem else { return }
        selectedItem = nil
        CaptureLibrary.shared.delete(item)   // libraryDidChange → reload()
    }

    func windowDidResize(_ notification: Notification) {
        previewScroll.refitIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .libraryDidChange, object: nil)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

/// 썸네일 그리드. 우클릭한 셀 위치를 indexPath로 넘겨 컨텍스트 메뉴를 구성하게 한다.
final class ThumbnailCollectionView: NSCollectionView {
    /// 우클릭한 항목의 indexPath로 표시할 메뉴를 만들어 반환. nil이면 메뉴 없음.
    var menuProvider: ((IndexPath) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return menuProvider?(indexPath)
    }
}

/// 확대/축소 가능한 스크롤뷰.
/// - ⌘+스크롤: 마우스 위치 기준 확대/축소
/// - ⌘+ / ⌘- / ⌘0: 확대 / 축소 / 창에 맞춤
final class ZoomableScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }

    /// '맞춤' 상태인지. 수동 줌을 하면 해제되고, 그동안은 창 크기에 따라 다시 맞춘다.
    private(set) var isFitMode = true

    func configure() {
        contentView = CenteringClipView()      // 이미지가 뷰보다 작으면 가운데 정렬
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 16
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let dy = event.scrollingDeltaY
        guard dy != 0, let document = documentView else { return }   // 0 델타(관성 꼬리)는 무시
        isFitMode = false
        // 배율을 먼저 [min,max]로 클램프해 둔다(시스템 클램프 후 앵커가 튀는 것 방지).
        let newMag = max(minMagnification, min(magnification * exp(dy * 0.01), maxMagnification))
        setMagnification(newMag, centeredAt: zoomAnchor(for: newMag, document: document, event: event))
    }

    /// 확대 후 이미지가 뷰보다 작으면 '중앙' 기준(센터링과 충돌해 떨리는 것 방지),
    /// 뷰보다 크면 '커서' 기준으로 줌한다.
    private func zoomAnchor(for mag: CGFloat, document: NSView, event: NSEvent) -> CGPoint {
        let scaledW = document.bounds.width * mag
        let scaledH = document.bounds.height * mag
        if scaledW <= contentView.frame.width && scaledH <= contentView.frame.height {
            return CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        }
        return contentView.convert(event.locationInWindow, from: nil)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoomBy(1.25)
        case "-", "_": zoomBy(0.8)
        case "0":      zoomToFit()
        default:       super.keyDown(with: event)
        }
    }

    func zoomBy(_ factor: CGFloat) {
        isFitMode = false
        let center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(magnification * factor, centeredAt: center)
    }

    /// 창 크기는 그대로 두고, 이미지가 미리보기 영역을 채우도록 배율을 맞춘다.
    /// 큰 캡처는 축소하고 작은 캡처는 확대해 → 캡처 크기와 무관하게 일관된 크기로 보인다.
    func zoomToFit() {
        isFitMode = true
        guard let document = documentView, document.bounds.width > 0, document.bounds.height > 0 else { return }
        // 가용 영역은 클립뷰의 '프레임'(화면 point) — 배율과 무관해 반복 호출에도 결과가 안정적이다.
        // (bounds.size 는 현재 배율로 스케일된 값이라, 그걸 쓰면 호출할 때마다 값이 진동한다.)
        // 가장자리에 여백을 둬서 크롭 꼭지점 핸들을 잡기 편하게 한다.
        let inset: CGFloat = 36
        let available = CGSize(width: max(1, contentView.frame.width - inset * 2),
                               height: max(1, contentView.frame.height - inset * 2))
        let fit = min(available.width / document.bounds.width,
                      available.height / document.bounds.height)
        magnification = max(minMagnification, min(fit, maxMagnification))
    }

    /// 창 크기가 바뀌었을 때 '맞춤' 상태면 다시 맞춘다.
    func refitIfNeeded() {
        if isFitMode { zoomToFit() }
    }
}

/// documentView가 클립뷰보다 작을 때 가운데로 정렬한다.
final class CenteringClipView: NSClipView {
    /// 이미지 바깥 여백을 클릭했을 때(=문서뷰 밖, 클립뷰 안), 크롭 중이면 그 클릭을
    /// 문서뷰(에디터)로 넘긴다. 에디터는 좌표를 가장자리로 clamp 해 가까운 크롭 핸들을 잡는다.
    /// → 핸들이 뷰 경계에 걸려 "눌렀는데 안 잡히던" 문제를 해결.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self, let editor = documentView as? EditorImageView, editor.wantsMarginClicks {
            return editor
        }
        return hit
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let docFrame = documentView.frame
        if rect.size.width >= docFrame.size.width {
            rect.origin.x = floor((docFrame.size.width - rect.size.width) / 2.0)
        }
        if rect.size.height >= docFrame.size.height {
            rect.origin.y = floor((docFrame.size.height - rect.size.height) / 2.0)
        }
        return rect
    }
}

/// 그리드 셀.
final class ThumbnailItem: NSCollectionViewItem {
    private let thumbView = NSImageView()

    /// 비동기 썸네일 로드 시 셀 재사용을 구분하기 위한 현재 표시 대상.
    var representedURL: URL?

    var thumbnail: NSImage? {
        didSet { thumbView.image = thumbnail }
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor
        container.layer?.borderColor = Brand.red.cgColor
        view = container

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(thumbView)
        NSLayoutConstraint.activate([
            thumbView.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            thumbView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
            thumbView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            thumbView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5)
        ])
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 3 : 0
        }
    }
}
