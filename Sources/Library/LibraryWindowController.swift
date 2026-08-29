import AppKit
import UniformTypeIdentifiers
import WebKit

/// 캡처 라이브러리 편집/뷰어 창.
/// 레이아웃: 네이티브 통합 툴바 + 접히는 사이드바(날짜별 썸네일) + 큰 미리보기.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate,
                                     NSToolbarDelegate, NSToolbarItemValidation {
    static let shared = LibraryWindowController()

    private var window: NSWindow?
    private var splitViewController: NSSplitViewController?
    private let collectionView = ThumbnailCollectionView()
    private let previewScroll = ZoomableScrollView()
    private let editorView = EditorImageView()
    private let videoEditorView = VideoEditorView()
    private let animatedImageView = WKWebView()
    private let emptyState = NSStackView()
    private let emptyHintLabel = NSTextField(wrappingLabelWithString: "")
    private let cropDoneButton = NSButton(title: "완료", target: nil, action: nil)
    private let cropCancelButton = NSButton(title: "취소", target: nil, action: nil)
    private let zoomButton = NSButton(title: "100%", target: nil, action: nil)
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider()
    private let widthLabel = NSTextField(labelWithString: "")
    private lazy var editToolControl = NSSegmentedControl(labels: [], trackingMode: .selectOne,
                                                          target: self, action: #selector(editToolChanged(_:)))
    private lazy var annotateToolControl = NSSegmentedControl(labels: [], trackingMode: .selectOne,
                                                              target: self, action: #selector(annotateToolChanged(_:)))

    // 편집 도구 (세그먼트 인덱스 → 도구). 두 그룹으로 나눠 "이미지를 자르는 것"과 "위에 그리는 것"을 구분한다.
    private let editTools: [EditorImageView.Tool] = [.none, .crop, .cutHorizontal, .cutVertical]
    private let annotateTools: [EditorImageView.Tool] = [.number, .text, .callout, .arrow, .rectangle, .ellipse, .mosaic]

    /// 날짜별 섹션(오늘 / 어제 / 최근 7일 / 이전).
    private struct Section {
        let title: String
        let items: [LibraryItem]
    }
    private var sections: [Section] = []
    private var styleControls: (color: NSView, width: NSView)?
    private var selectedItem: LibraryItem?
    private var keyMonitor: Any?
    private var boundsObserver: Any?

    /// 캡처 세션 동안 라이브러리 창을 잠시 숨겼는지. 복원 여부 판단에 쓴다.
    private var hiddenForCapture = false

    /// 다음 목록 반영 시 (이전 선택 대신) 가장 최신 항목을 선택할지.
    /// 캡처 직후 새로 저장된 항목을 자동으로 보여주기 위한 1회성 플래그.
    private var selectLatestPending = false

    private let itemIdentifier = NSUserInterfaceItemIdentifier("ThumbnailItem")
    private let headerIdentifier = NSUserInterfaceItemIdentifier("ThumbnailSectionHeader")

    private enum ToolbarID {
        static let editTools = NSToolbarItem.Identifier("editTools")
        static let annotateTools = NSToolbarItem.Identifier("annotateTools")
        static let color = NSToolbarItem.Identifier("color")
        static let width = NSToolbarItem.Identifier("width")
        static let undo = NSToolbarItem.Identifier("undo")
        static let copy = NSToolbarItem.Identifier("copy")
        static let save = NSToolbarItem.Identifier("save")
        static let reveal = NSToolbarItem.Identifier("reveal")
        static let delete = NSToolbarItem.Identifier("delete")
    }

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
            guard let self, let window = self.window, window.isVisible, window.isKeyWindow else { return event }
            let significantFlags = event.modifierFlags.intersection([.command, .option, .control])
            if event.keyCode == 49, significantFlags.isEmpty, self.videoEditorView.isHidden == false {
                self.videoEditorView.togglePlayback()
                return nil
            }
            // 썸네일 목록에 포커스가 있을 때 ⌫ → 휴지통으로. (에디터 포커스면 주석 삭제가 우선)
            if (event.keyCode == 51 || event.keyCode == 117), significantFlags.isEmpty,
               window.firstResponder === self.collectionView {
                self.deleteSelected()
                return nil
            }
            guard event.modifierFlags.contains(.command) else { return event }
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
        let contentRect = NSRect(x: 0, y: 0, width: 960, height: 620)
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "라이브러리"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 460)

        let sidebar = buildSidebar()
        let preview = buildPreview()

        let split = NSSplitViewController()
        split.splitView.autosaveName = "LibrarySplitV1"
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: ContainerViewController(view: sidebar))
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        let previewItem = NSSplitViewItem(viewController: ContainerViewController(view: preview))
        previewItem.minimumThickness = 420
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(previewItem)
        split.view.frame = contentRect
        splitViewController = split
        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "LibraryToolbarV1")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel          // 아이콘+텍스트 고정
        toolbar.allowsUserCustomization = false
        if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = false }
        window.toolbar = toolbar

        window.setFrame(contentRect, display: false)
        window.center()
        window.setFrameAutosaveName("LibraryWindowV3")
        self.window = window
        NotificationCenter.default.addObserver(self, selector: #selector(refreshEmptyHint),
                                               name: .hotkeyChanged, object: nil)
        syncToolControl(to: editorView.tool)
    }

    private func buildSidebar() -> NSView {
        let flow = NSCollectionViewFlowLayout()
        flow.itemSize = NSSize(width: 116, height: 122)
        flow.minimumInteritemSpacing = 8
        flow.minimumLineSpacing = 8
        flow.sectionInset = NSEdgeInsets(top: 4, left: 10, bottom: 12, right: 10)
        flow.headerReferenceSize = NSSize(width: 0, height: 26)
        collectionView.collectionViewLayout = flow
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: itemIdentifier)
        collectionView.register(ThumbnailSectionHeader.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: headerIdentifier)
        // 썸네일을 다른 앱(Finder/메일/슬랙 등)으로 끌어다 놓으면 실제 파일이 첨부되도록
        // 앱 바깥 드래그를 복사 동작으로 허용한다.
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        // 썸네일 우클릭 → 컨텍스트 메뉴
        collectionView.menuProvider = { [weak self] indexPath in
            guard let self, self.item(at: indexPath) != nil else { return nil }
            self.select(indexPath)     // 우클릭한 항목을 선택 + 미리보기로
            let menu = NSMenu()
            for (title, action) in [("클립보드에 복사", #selector(self.copySelected)),
                                    ("Finder에서 보기", #selector(self.revealSelected)),
                                    ("다른 이름으로 저장…", #selector(self.saveSelected))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let trash = NSMenuItem(title: "휴지통으로 이동", action: #selector(self.deleteSelected), keyEquivalent: "")
            trash.target = self
            menu.addItem(trash)
            return menu
        }

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false          // 사이드바 재질이 비치도록
        scroll.automaticallyAdjustsContentInsets = true
        return scroll
    }

    private func buildPreview() -> NSView {
        let previewContainer = NSView()
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        editorView.onImageChanged = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.previewScroll.zoomToFit()
                self.window?.makeFirstResponder(self.editorView)
            }
        }
        editorView.onCropProgress = { [weak self] progressed in
            self?.cropDoneButton.isHidden = !progressed
            self?.cropCancelButton.isHidden = !progressed
        }
        editorView.onDidCopy = { [weak self] in
            self?.showToast("클립보드에 복사됨")
        }
        // 크롭 적용/되돌리기로 이미지가 바뀌면 라이브러리 파일에 반영하고 썸네일만 갱신.
        // (에디터를 reload하지 않으므로 undo 스택이 보존된다 → 크롭도 ⌘Z로 되돌릴 수 있음)
        editorView.onEditCommitted = { [weak self] in
            self?.persistCurrentEdit()
        }
        editorView.onToolChanged = { [weak self] tool in
            self?.syncToolControl(to: tool)
        }
        // 주석을 선택하면 툴바의 색·굵기가 그 주석을 가리키고, 이후 변경은 그 주석에 적용된다.
        // (툴바 = "현재 스타일": 선택된 것과 앞으로 그릴 것 모두에 해당)
        editorView.onSelectionChanged = { [weak self] annotation in
            guard let self, let annotation else { return }
            if case .mosaic = annotation.kind { return }
            self.editorView.strokeColor = annotation.color
            self.editorView.strokeWidth = annotation.width
            self.colorWell.color = annotation.color
            self.widthSlider.doubleValue = Double(annotation.width)
            self.updateWidthLabel()
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

        // 배율 표시: 스크롤뷰 bounds가 바뀔 때(줌·핀치 포함)마다 갱신.
        previewScroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                object: previewScroll.contentView,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateZoomLabel() }
        }

        videoEditorView.translatesAutoresizingMaskIntoConstraints = false
        videoEditorView.isHidden = true
        previewContainer.addSubview(videoEditorView)

        animatedImageView.translatesAutoresizingMaskIntoConstraints = false
        animatedImageView.isHidden = true
        previewContainer.addSubview(animatedImageView)

        buildEmptyState()
        previewContainer.addSubview(emptyState)

        // 크롭 진행 시 떠오르는 [완료]/[취소] 버튼
        cropDoneButton.bezelStyle = .rounded
        cropDoneButton.controlSize = .large
        cropDoneButton.keyEquivalent = "\r"
        cropDoneButton.target = self
        cropDoneButton.action = #selector(commitCrop)
        cropDoneButton.isHidden = true
        if #available(macOS 11.0, *) { cropDoneButton.bezelColor = Brand.red }
        cropCancelButton.bezelStyle = .rounded
        cropCancelButton.controlSize = .large
        cropCancelButton.target = self
        cropCancelButton.action = #selector(cancelCrop)
        cropCancelButton.isHidden = true
        let cropButtons = NSStackView(views: [cropCancelButton, cropDoneButton])
        cropButtons.orientation = .horizontal
        cropButtons.spacing = 8
        cropButtons.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(cropButtons)

        // 배율 알약 — 클릭하면 창에 맞춤
        zoomButton.bezelStyle = .inline
        zoomButton.isBordered = true
        zoomButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomButton.contentTintColor = .secondaryLabelColor
        zoomButton.toolTip = "창에 맞춤 (⌘0) · ⌘+/⌘- 또는 ⌘+스크롤로 확대/축소"
        zoomButton.target = self
        zoomButton.action = #selector(zoomFit)
        zoomButton.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(zoomButton)

        NSLayoutConstraint.activate([
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

            emptyState.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 360),

            cropButtons.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            cropButtons.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -18),

            zoomButton.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -14),
            zoomButton.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -12)
        ])
        return previewContainer
    }

    private func buildEmptyState() {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 44, weight: .light)
        let icon = NSImageView(image: NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: "아직 캡처가 없어요")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center

        emptyHintLabel.font = .systemFont(ofSize: 12)
        emptyHintLabel.textColor = .tertiaryLabelColor
        emptyHintLabel.alignment = .center
        refreshEmptyHint()

        let captureButton = NSButton(title: "지금 캡처", target: self, action: #selector(captureNow))
        AppAppearance.accentButton(captureButton)
        captureButton.controlSize = .large

        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addArrangedSubview(icon)
        emptyState.addArrangedSubview(title)
        emptyState.addArrangedSubview(emptyHintLabel)
        emptyState.setCustomSpacing(16, after: emptyHintLabel)
        emptyState.addArrangedSubview(captureButton)
        emptyState.isHidden = true
    }

    @objc private func refreshEmptyHint() {
        let shortcut = HotkeyFormatter.displayString(keyCode: Settings.shared.hotKeyCode,
                                                     carbonModifiers: Settings.shared.hotKeyModifiers)
        emptyHintLabel.stringValue = "\(shortcut) 를 누르면 화면 어디서든 캡처할 수 있고,\n결과는 클립보드와 여기에 함께 담깁니다."
    }

    /// 주석 스타일(색·굵기)은 항상 툴바에 보인다 — 도구를 고르기 전에 정하고, 고른 뒤에도 바로 바꿀 수 있게.
    private func buildStyleControls() -> (color: NSView, width: NSView) {
        colorWell.color = Brand.red
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        if #available(macOS 13.0, *) { colorWell.colorWellStyle = .minimal }
        colorWell.widthAnchor.constraint(equalToConstant: 34).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        colorWell.toolTip = "주석 색상 (번호·텍스트·말풍선·화살표·도형)"

        widthSlider.minValue = 1
        widthSlider.maxValue = 20
        widthSlider.doubleValue = Double(editorView.strokeWidth)
        widthSlider.isContinuous = true
        widthSlider.controlSize = .small
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged(_:))
        widthSlider.widthAnchor.constraint(equalToConstant: 88).isActive = true
        widthSlider.toolTip = "선 굵기 · 텍스트 크기 (1–20px)"

        widthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        widthLabel.textColor = .secondaryLabelColor
        widthLabel.alignment = .right
        widthLabel.widthAnchor.constraint(equalToConstant: 30).isActive = true
        updateWidthLabel()

        let widthRow = NSStackView(views: [widthSlider, widthLabel])
        widthRow.orientation = .horizontal
        widthRow.alignment = .centerY
        widthRow.spacing = 4
        return (colorWell, widthRow)
    }

    private func updateWidthLabel() {
        widthLabel.stringValue = "\(Int(editorView.strokeWidth))px"
    }

    // MARK: 툴바
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator,
         ToolbarID.editTools, ToolbarID.annotateTools, ToolbarID.color, ToolbarID.width, ToolbarID.undo,
         .flexibleSpace,
         ToolbarID.copy, ToolbarID.save, ToolbarID.reveal, ToolbarID.delete]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.editTools:
            configure(editToolControl,
                      symbols: ["cursorarrow", "crop", "arrow.down.and.line.horizontal.and.arrow.up", "arrow.right.and.line.vertical.and.arrow.left"],
                      tips: ["선택 · 주석 이동 (방향키로 1px, ⇧방향키로 10px)", "크롭 (드래그 후 ⏎ 적용)",
                             "가로 띠 잘라내기 — 위아래로 드래그한 구간을 없애고 높이를 줄임",
                             "세로 띠 잘라내기 — 좌우로 드래그한 구간을 없애고 너비를 줄임"])
            return viewItem(itemIdentifier, view: editToolControl, label: "편집")
        case ToolbarID.annotateTools:
            configure(annotateToolControl,
                      symbols: ["1.circle", "textformat", "text.bubble", "arrow.up.right", "rectangle", "circle", "checkerboard.rectangle"],
                      tips: ["번호 ➊–➒ (클릭)", "텍스트 (클릭 후 입력)", "말풍선 (가리킬 곳에서 드래그)", "화살표 (⇧ 45° 스냅)", "사각형 (⇧ 정사각형)", "원 (⇧ 정원)", "모자이크 (드래그)"])
            return viewItem(itemIdentifier, view: annotateToolControl, label: "주석")
        case ToolbarID.color:
            if styleControls == nil { styleControls = buildStyleControls() }
            return viewItem(itemIdentifier, view: styleControls!.color, label: "색상")
        case ToolbarID.width:
            if styleControls == nil { styleControls = buildStyleControls() }
            return viewItem(itemIdentifier, view: styleControls!.width, label: "굵기")
        case ToolbarID.undo:
            return actionItem(itemIdentifier, symbol: "arrow.uturn.backward", label: "되돌리기", tip: "되돌리기 (⌘Z)", action: #selector(undoEdit))
        case ToolbarID.copy:
            return actionItem(itemIdentifier, symbol: "doc.on.clipboard", label: "복사", tip: "클립보드에 복사 (⌘C)", action: #selector(copySelected))
        case ToolbarID.save:
            return actionItem(itemIdentifier, symbol: "square.and.arrow.down", label: "저장", tip: "다른 이름으로 저장…", action: #selector(saveSelected))
        case ToolbarID.reveal:
            return actionItem(itemIdentifier, symbol: "folder", label: "Finder", tip: "Finder에서 보기", action: #selector(revealSelected))
        case ToolbarID.delete:
            return actionItem(itemIdentifier, symbol: "trash", label: "삭제", tip: "휴지통으로 이동 (⌫)", action: #selector(deleteSelected))
        default:
            return nil
        }
    }

    private func configure(_ control: NSSegmentedControl, symbols: [String], tips: [String]) {
        guard control.segmentCount != symbols.count else { return }
        control.segmentCount = symbols.count
        control.segmentStyle = .automatic
        for (i, symbol) in symbols.enumerated() {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tips[i])
                ?? NSImage(systemSymbolName: "rectangle.compress.vertical", accessibilityDescription: tips[i])
            control.setImage(image, forSegment: i)
            control.setToolTip(tips[i], forSegment: i)
            control.setWidth(32, forSegment: i)
        }
        control.selectedSegment = -1
    }

    private func viewItem(_ id: NSToolbarItem.Identifier, view: NSView, label: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = view
        item.label = label
        item.paletteLabel = label
        return item
    }

    private func actionItem(_ id: NSToolbarItem.Identifier, symbol: String, label: String, tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ToolbarID.undo, ToolbarID.copy, ToolbarID.color, ToolbarID.width:
            return selectedItem?.kind == .image
        case ToolbarID.save, ToolbarID.reveal, ToolbarID.delete:
            return selectedItem != nil
        default:
            return true
        }
    }

    // MARK: 데이터
    @objc private func reload() {
        // 바탕화면 목록 읽기는 백그라운드에서 (TCC 동의창이 메인을 막지 않도록).
        CaptureLibrary.shared.loadItems { [weak self] items in
            self?.applyItems(items)
        }
    }

    private func applyItems(_ items: [LibraryItem]) {
        sections = Self.groupByDate(items)
        collectionView.reloadData()
        window?.subtitle = items.isEmpty ? "" : "\(items.count)개 항목"

        // 캡처 직후: 이전 선택을 무시하고 방금 저장된 최신(첫) 항목을 선택.
        if selectLatestPending, let first = firstIndexPath {
            selectLatestPending = false
            select(first)
            return
        }

        // 선택 유지 또는 첫 항목 선택
        if let selected = selectedItem, let indexPath = indexPath(for: selected.url) {
            select(indexPath)
        } else if let first = firstIndexPath {
            select(first)
        } else {
            selectedItem = nil
            editorView.image = nil
            videoEditorView.stop()
            videoEditorView.isHidden = true
            animatedImageView.loadHTMLString("", baseURL: nil)
            animatedImageView.isHidden = true
            previewScroll.isHidden = true
            zoomButton.isHidden = true
            emptyState.isHidden = false
            window?.toolbar?.validateVisibleItems()
        }
    }

    /// 목록(최신순)을 오늘 / 어제 / 최근 7일 / 이전 섹션으로 나눈다.
    private static func groupByDate(_ items: [LibraryItem]) -> [Section] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today

        var buckets: [(String, [LibraryItem])] = [("오늘", []), ("어제", []), ("최근 7일", []), ("이전", [])]
        for item in items {
            if item.date >= today { buckets[0].1.append(item) }
            else if item.date >= yesterday { buckets[1].1.append(item) }
            else if item.date >= weekAgo { buckets[2].1.append(item) }
            else { buckets[3].1.append(item) }
        }
        return buckets.filter { !$0.1.isEmpty }.map { Section(title: $0.0, items: $0.1) }
    }

    private func item(at indexPath: IndexPath) -> LibraryItem? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].items.indices.contains(indexPath.item) else { return nil }
        return sections[indexPath.section].items[indexPath.item]
    }

    private func indexPath(for url: URL) -> IndexPath? {
        for (s, section) in sections.enumerated() {
            if let i = section.items.firstIndex(where: { $0.url == url }) {
                return IndexPath(item: i, section: s)
            }
        }
        return nil
    }

    private var firstIndexPath: IndexPath? {
        sections.isEmpty ? nil : IndexPath(item: 0, section: 0)
    }

    private func select(_ indexPath: IndexPath) {
        guard let item = item(at: indexPath) else { return }
        collectionView.selectionIndexPaths = [indexPath]
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
        showPreview(item)
    }

    private func showPreview(_ item: LibraryItem) {
        selectedItem = item
        emptyState.isHidden = true
        cropDoneButton.isHidden = true
        cropCancelButton.isHidden = true
        switch item.kind {
        case .video:
            editorView.image = nil
            animatedImageView.loadHTMLString("", baseURL: nil)
            animatedImageView.isHidden = true
            previewScroll.isHidden = true
            zoomButton.isHidden = true
            videoEditorView.isHidden = false
            videoEditorView.load(url: item.url)
        case .animatedImage:
            editorView.image = nil
            videoEditorView.stop()
            videoEditorView.isHidden = true
            previewScroll.isHidden = true
            zoomButton.isHidden = true
            animatedImageView.isHidden = false
            showAnimatedImagePreview(item)
        case .image:
            videoEditorView.stop()
            videoEditorView.isHidden = true
            animatedImageView.loadHTMLString("", baseURL: nil)
            animatedImageView.isHidden = true
            previewScroll.isHidden = false
            zoomButton.isHidden = false
            showImagePreview(item)
        }
        window?.toolbar?.validateVisibleItems()
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

    private func updateZoomLabel() {
        let scale = window?.backingScaleFactor ?? 2
        // 에디터 문서는 픽셀 크기라, 화면 픽셀 1:1이 100%가 되도록 백킹 배율을 곱한다.
        let percent = Int((previewScroll.magnification * scale * 100).rounded())
        zoomButton.title = "\(percent)%"
    }

    // MARK: NSCollectionView
    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: headerIdentifier, for: indexPath)
        (header as? ThumbnailSectionHeader)?.title = sections[indexPath.section].title
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: itemIdentifier, for: indexPath) as! ThumbnailItem
        guard let libraryItem = item(at: indexPath) else { return cell }
        // 셀 재사용 대비: 비동기 로드 후 셀이 가리키는 URL이 그대로일 때만 적용.
        cell.configure(with: libraryItem)
        cell.thumbnail = nil
        CaptureLibrary.shared.thumbnail(for: libraryItem.url) { image in
            if cell.representedURL == libraryItem.url { cell.thumbnail = image }
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let indexPath = indexPaths.first, let item = item(at: indexPath) {
            showPreview(item)
        }
    }

    // MARK: 드래그앤드롭 (썸네일 → 외부 앱 파일 첨부)
    func collectionView(_ collectionView: NSCollectionView,
                        canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool {
        true
    }

    /// 항목의 실제 파일 URL을 pasteboard에 실어, 드롭한 곳에 파일 자체가 전달되게 한다.
    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        item(at: indexPath)?.url as NSURL?
    }

    // MARK: 편집 도구 액션
    @objc private func editToolChanged(_ sender: NSSegmentedControl) {
        guard editTools.indices.contains(sender.selectedSegment) else { return }
        editorView.tool = editTools[sender.selectedSegment]
        window?.makeFirstResponder(editorView)
    }

    @objc private func annotateToolChanged(_ sender: NSSegmentedControl) {
        guard annotateTools.indices.contains(sender.selectedSegment) else { return }
        editorView.tool = annotateTools[sender.selectedSegment]
        window?.makeFirstResponder(editorView)
    }

    /// 에디터의 현재 도구를 두 세그먼트 그룹에 반영한다.
    private func syncToolControl(to tool: EditorImageView.Tool) {
        editToolControl.selectedSegment = editTools.firstIndex(of: tool) ?? -1
        annotateToolControl.selectedSegment = annotateTools.firstIndex(of: tool) ?? -1
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        editorView.strokeColor = sender.color
        editorView.applyStyleToSelection(color: sender.color, undoKey: "color")
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        let width = CGFloat(sender.doubleValue.rounded())
        editorView.strokeWidth = width
        editorView.applyStyleToSelection(width: width, undoKey: "width")
        updateWidthLabel()
    }

    @objc private func undoEdit() {
        editorView.undo()
    }

    @objc private func copySelected() {
        editorView.copyToClipboard()
    }

    @objc private func captureNow() {
        CaptureCoordinator.shared.startAreaCapture()
    }

    private func showToast(_ message: String) {
        guard let content = window?.contentView else { return }
        let pill = HUDSurfaceView(frame: .zero)
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
        cropCancelButton.isHidden = true
    }

    @objc private func cancelCrop() {
        editorView.tool = .none
        cropDoneButton.isHidden = true
        cropCancelButton.isHidden = true
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
        guard let indexPath = indexPath(for: url) else { return }
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
        showToast("휴지통으로 이동함")
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

/// 미리 만든 뷰를 그대로 감싸는 얇은 뷰 컨트롤러 (NSSplitViewController 항목용).
private final class ContainerViewController: NSViewController {
    private let contentView: NSView

    init(view: NSView) {
        self.contentView = view
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = contentView
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

    override func mouseDown(with event: NSEvent) {
        if let editor = documentView as? EditorImageView {
            editor.cancelSelectionAndToolFromMarginClick()
        }
        super.mouseDown(with: event)
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

/// 섹션 머리글 (오늘 / 어제 / …). 사이드바 재질 위에 얹히므로 배경 없이 글자만.
final class ThumbnailSectionHeader: NSView, NSCollectionViewElement {
    private let label = NSTextField(labelWithString: "")

    var title: String = "" {
        didSet { label.stringValue = title }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 그리드 셀: 썸네일 + 상대 시간 + 종류 배지(GIF/MP4).
final class ThumbnailItem: NSCollectionViewItem {
    private let thumbView = NSImageView()
    private let timeLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")

    /// 비동기 썸네일 로드 시 셀 재사용을 구분하기 위한 현재 표시 대상.
    private(set) var representedURL: URL?

    var thumbnail: NSImage? {
        didSet { thumbView.image = thumbnail }
    }

    func configure(with item: LibraryItem) {
        representedURL = item.url
        timeLabel.stringValue = Self.relativeTime(item.date)
        view.toolTip = item.url.lastPathComponent
        switch item.kind {
        case .image:
            badgeLabel.isHidden = true
        case .animatedImage:
            badgeLabel.isHidden = false
            badgeLabel.stringValue = "GIF"
        case .video:
            badgeLabel.isHidden = false
            badgeLabel.stringValue = item.url.pathExtension.uppercased()
        }
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = Brand.innerCornerRadius
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        container.layer?.borderColor = Brand.red.cgColor
        view = container

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(thumbView)

        timeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.maximumNumberOfLines = 1
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(timeLabel)

        badgeLabel.font = .systemFont(ofSize: 9, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        badgeLabel.layer?.cornerRadius = 4
        badgeLabel.isHidden = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            thumbView.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            thumbView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            thumbView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            thumbView.bottomAnchor.constraint(equalTo: timeLabel.topAnchor, constant: -4),

            timeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            timeLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
            timeLabel.heightAnchor.constraint(equalToConstant: 14),

            badgeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
            badgeLabel.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            badgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: timeLabel.trailingAnchor, constant: 4),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            badgeLabel.heightAnchor.constraint(equalToConstant: 13)
        ])
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 2 : 0
        }
    }

    /// "방금 전" / "14:03" / "어제 14:03" / "8월 20일" — 파일명 대신 사람이 읽는 시간.
    private static func relativeTime(_ date: Date) -> String {
        let now = Date()
        if now.timeIntervalSince(date) < 60 { return "방금 전" }
        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "어제 \(time)" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return dayFormatter.string(from: date) }
        return fullFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "HH:mm"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M월 d일"; return f
    }()
    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "yyyy. M. d."; return f
    }()
}
