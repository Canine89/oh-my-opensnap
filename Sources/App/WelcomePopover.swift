import AppKit

extension Notification.Name {
    /// 설정 창 등에서 "시작 안내 다시 보기"를 요청할 때. 메뉴 막대 컨트롤러가 받아 팝오버를 띄운다.
    static let showWelcomeRequested = Notification.Name("com.goldenrabbit.ohmyopensnap.showWelcomeRequested")
}

/// 첫 실행 안내. Dock 아이콘이 없는 앱이라 "어디에 있는지 · 어떻게 부르는지 · 무슨 권한이 필요한지"
/// 세 가지를 메뉴 막대 아이콘에서 뻗어 나오는 팝오버로 보여 준다.
/// 맨 위의 언어 선택(기본 영어)은 즉시 적용되고, 이후 설정 창에서도 바꿀 수 있다.
@MainActor
final class WelcomePopover: NSObject, NSPopoverDelegate {
    private static let shownKey = "didShowWelcome"

    static var wasShown: Bool { UserDefaults.standard.bool(forKey: shownKey) }
    static func markShown() { UserDefaults.standard.set(true, forKey: shownKey) }

    private let popover = NSPopover()
    private let permissionStatus = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "", target: nil, action: nil)
    private var timer: Timer?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = makeContent()
        // 언어가 바뀌면 (여기 세그먼트로든 설정 창에서든) 열린 채로 내용을 새 언어로 다시 그린다.
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildContent),
                                               name: .appLanguageDidChange, object: nil)
    }

    func show(relativeTo view: NSView) {
        guard !popover.isShown else { return }
        Self.markShown()
        refreshPermission()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    @objc private func rebuildContent() {
        popover.contentViewController = makeContent()
        refreshPermission()
    }

    private func makeContent() -> NSViewController {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let title = NSTextField(labelWithString: loc("\(Brand.name) lives in your menu bar",
                                                     "\(Brand.name)이 메뉴 막대에 있어요"))
        title.font = .systemFont(ofSize: 16, weight: .bold)
        let subtitle = AppAppearance.secondaryText(loc("It never appears in the Dock. Click the icon above to open the menu.",
                                                       "Dock에는 나타나지 않습니다. 위의 아이콘을 누르면 메뉴가 열립니다."), size: 12)

        // 언어 선택 — 기본은 영어, 한국어로 즉시 전환 가능. 각 언어는 항상 자기 표기로 보여 준다.
        let languageLabel = AppAppearance.secondaryText(loc("Language · 언어", "Language · 언어"), size: 11)
        let languageControl = NSSegmentedControl(labels: AppLanguage.allCases.map(\.displayName),
                                                 trackingMode: .selectOne,
                                                 target: self, action: #selector(languagePicked(_:)))
        languageControl.selectedSegment = AppLanguage.allCases.firstIndex(of: Settings.shared.appLanguage) ?? 0
        let languageRow = NSStackView(views: [languageLabel, languageControl])
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY
        languageRow.spacing = 8

        let shortcut = HotkeyFormatter.displayString(keyCode: Settings.shared.hotKeyCode,
                                                     carbonModifiers: Settings.shared.hotKeyModifiers)
        let step1 = stepRow(number: 1, symbol: "keyboard",
                            title: loc("Capture anywhere with \(shortcut)",
                                       "어디서든 \(shortcut) 로 캡처"),
                            detail: loc("Drag to select an area, or click a window to grab just that window. You can change the shortcut in Settings.",
                                        "드래그해 영역을 고르거나, 창을 클릭하면 창만 잡힙니다. 단축키는 설정에서 바꿀 수 있어요."))

        permissionStatus.font = .systemFont(ofSize: 11)
        permissionStatus.textColor = .secondaryLabelColor
        permissionButton.title = loc("Allow Permission", "권한 허용")
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        let permissionRow = NSStackView(views: [permissionStatus, permissionButton])
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 8
        let step2 = stepRow(number: 2, symbol: "lock.shield",
                            title: loc("Allow Screen Recording once", "화면 녹화 권한 한 번 허용"),
                            detail: loc("This is the standard macOS permission. Capturing cannot work without it.",
                                        "macOS가 묻는 표준 권한입니다. 캡처는 이 권한 없이는 동작하지 않아요."),
                            accessory: permissionRow)

        let step3 = stepRow(number: 3, symbol: "doc.on.clipboard",
                            title: loc("Capture, then paste right away", "캡처하면 바로 붙여넣기"),
                            detail: loc("Results are copied to the clipboard instantly and collected in the library for annotating and cropping later.",
                                        "결과는 클립보드에 즉시 복사되고, 라이브러리에 모여 나중에 주석·크롭할 수 있습니다."))

        let done = NSButton(title: loc("Get Started", "시작하기"), target: self, action: #selector(close))
        AppAppearance.accentButton(done)
        done.keyEquivalent = "\r"
        let buttonRow = NSStackView(views: [NSView(), done])
        buttonRow.orientation = .horizontal

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        let headerRow = NSStackView(views: [icon, header])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12

        let stack = NSStackView(views: [headerRow, languageRow, step1, step2, step3, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(14, after: headerRow)
        stack.setCustomSpacing(18, after: languageRow)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 400),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            step1.widthAnchor.constraint(equalTo: buttonRow.widthAnchor),
            step2.widthAnchor.constraint(equalTo: buttonRow.widthAnchor),
            step3.widthAnchor.constraint(equalTo: buttonRow.widthAnchor)
        ])

        let controller = NSViewController()
        controller.view = container
        return controller
    }

    @objc private func languagePicked(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0, sender.selectedSegment < AppLanguage.allCases.count else { return }
        Settings.shared.appLanguage = AppLanguage.allCases[sender.selectedSegment]
    }

    private func stepRow(number: Int, symbol: String, title: String, detail: String, accessory: NSView? = nil) -> NSView {
        let badge = NSTextField(labelWithString: "\(number)")
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = Brand.red.cgColor
        badge.layer?.cornerRadius = 10
        badge.widthAnchor.constraint(equalToConstant: 20).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = AppAppearance.secondaryText(detail, size: 11)

        let text = NSStackView(views: [titleLabel, detailLabel])
        if let accessory { text.addArrangedSubview(accessory) }
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let row = NSStackView(views: [badge, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        detailLabel.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        return row
    }

    private func refreshPermission() {
        if ScreenCapturePermission.isGranted {
            permissionStatus.stringValue = loc("✓ Granted", "✓ 허용됨")
            permissionStatus.textColor = .systemGreen
            permissionButton.isHidden = true
        } else {
            permissionStatus.stringValue = loc("Not granted yet", "아직 허용되지 않음")
            permissionStatus.textColor = .systemOrange
            permissionButton.isHidden = false
        }
    }

    @objc private func requestPermission() {
        if !ScreenCapturePermission.request() {
            // 이미 한 번 거부된 경우 prompt가 다시 뜨지 않는다 → 설정으로 안내
            ScreenCapturePermission.openSystemSettings()
        }
        refreshPermission()
    }

    @objc private func close() {
        popover.performClose(nil)
    }
}
