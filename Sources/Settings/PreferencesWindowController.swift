import AppKit

/// 환경설정 창: 툴바 탭(일반 / 저장 / 권한 / 정보). 표준 macOS 설정 창 구조를 따른다.
@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let tabs = NSTabViewController()

    private var pathControl: NSPathControl?
    private var recordButton: NSButton?
    private var recordHint: NSTextField?
    private var launchAtLoginCheck: NSButton?
    private var permissionBanner: NSView?
    private var screenStatus: PermissionStatusRow?
    #if !MAS
    private var accessibilityStatus: PermissionStatusRow?
    #endif
    private var permissionTimer: Timer?
    private var recordingMonitor: Any?
    private var isRecording = false

    func showWindow() {
        if window == nil { buildWindow() }
        refreshLaunchAtLoginState()
        refreshPermissionStatus()
        startPermissionMonitor()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: 구성
    private func buildWindow() {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        buildTabs()

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = loc("\(Brand.name) Settings", "\(Brand.name) 설정")
        window.toolbarStyle = .preference
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PreferencesV2")
        self.window = window

        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged),
                                               name: .appLanguageDidChange, object: nil)
    }

    private func buildTabs() {
        tabs.addTabViewItem(tabItem(loc("General", "일반"), symbol: "gearshape", view: buildGeneralPane()))
        tabs.addTabViewItem(tabItem(loc("Storage", "저장"), symbol: "folder", view: buildStoragePane()))
        tabs.addTabViewItem(tabItem(loc("Permissions", "권한"), symbol: "lock.shield", view: buildPermissionsPane()))
        tabs.addTabViewItem(tabItem(loc("About", "정보"), symbol: "info.circle", view: buildAboutPane()))
    }

    /// 언어가 바뀌면 창을 연 채로 탭 내용을 새 언어로 다시 만든다 (선택된 탭 유지).
    @objc private func languageChanged() {
        guard window != nil else { return }
        let selected = tabs.selectedTabViewItemIndex
        stopRecording()
        while let first = tabs.tabViewItems.first { tabs.removeTabViewItem(first) }
        buildTabs()
        tabs.selectedTabViewItemIndex = selected
        window?.title = loc("\(Brand.name) Settings", "\(Brand.name) 설정")
        refreshLaunchAtLoginState()
        refreshPermissionStatus()
    }

    private func tabItem(_ label: String, symbol: String, view: NSView) -> NSTabViewItem {
        let controller = NSViewController()
        controller.view = view
        // 탭마다 내용 높이가 달라 창이 탭에 맞춰 늘고 준다.
        view.widthAnchor.constraint(equalToConstant: 520).isActive = true
        controller.preferredContentSize = view.fittingSize
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    private func pane(_ views: [NSView], spacing: CGFloat = 14) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 22, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        for view in views where view is NSTextField || view is NSStackView || view is NSVisualEffectView {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }
        return container
    }

    private func checkbox(_ title: String, detail: String? = nil, on: Bool, action: Selector) -> NSView {
        let check = NSButton(checkboxWithTitle: title, target: self, action: action)
        check.state = on ? .on : .off
        guard let detail else { return check }
        let hint = AppAppearance.secondaryText(detail)
        let stack = NSStackView(views: [check, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        hint.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20).isActive = true
        return stack
    }

    // MARK: 일반
    private func buildGeneralPane() -> NSView {
        // 권한이 없을 때만 보이는 배너 — 있는 사람에겐 소음이 되지 않게.
        let bannerIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        bannerIcon.contentTintColor = .systemOrange
        let bannerText = AppAppearance.secondaryText(loc("Screen Recording permission is missing, so capture cannot work yet.", "화면 녹화 권한이 아직 없어 캡처가 동작하지 않습니다."), size: 12)
        bannerText.textColor = .labelColor
        let bannerButton = NSButton(title: loc("Open Permissions Tab", "권한 탭으로"), target: self, action: #selector(goToPermissions))
        bannerButton.bezelStyle = .rounded
        bannerButton.controlSize = .small
        let bannerRow = NSStackView(views: [bannerIcon, bannerText, bannerButton])
        bannerRow.orientation = .horizontal
        bannerRow.alignment = .centerY
        bannerRow.spacing = 8
        bannerRow.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        bannerRow.translatesAutoresizingMaskIntoConstraints = false
        let banner = NSVisualEffectView()
        banner.material = .contentBackground
        banner.blendingMode = .withinWindow
        banner.wantsLayer = true
        banner.layer?.cornerRadius = Brand.innerCornerRadius
        banner.layer?.borderWidth = 1
        banner.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.5).cgColor
        banner.addSubview(bannerRow)
        NSLayoutConstraint.activate([
            bannerRow.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            bannerRow.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            bannerRow.topAnchor.constraint(equalTo: banner.topAnchor),
            bannerRow.bottomAnchor.constraint(equalTo: banner.bottomAnchor)
        ])
        banner.isHidden = ScreenCapturePermission.isGranted
        permissionBanner = banner

        // 언어 — 각 언어는 항상 자기 표기로 보여 준다.
        let languageLabel = NSTextField(labelWithString: loc("Language · 언어", "Language · 언어"))
        languageLabel.font = .systemFont(ofSize: 13)
        let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        languagePopup.addItems(withTitles: AppLanguage.allCases.map(\.displayName))
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: Settings.shared.appLanguage) ?? 0)
        languagePopup.target = self
        languagePopup.action = #selector(languagePicked(_:))
        let languageRow = NSStackView(views: [languageLabel, languagePopup])
        languageRow.orientation = .horizontal
        languageRow.alignment = .firstBaseline
        languageRow.spacing = 10

        // 단축키 레코더
        let shortcutLabel = NSTextField(labelWithString: loc("Capture shortcut", "캡처 단축키"))
        shortcutLabel.font = .systemFont(ofSize: 13)
        let recordButton = NSButton(title: currentShortcutString(), target: self, action: #selector(toggleRecording))
        recordButton.bezelStyle = .rounded
        recordButton.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        recordButton.setButtonType(.momentaryPushIn)
        recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        self.recordButton = recordButton
        let recordHint = AppAppearance.secondaryText(loc("Click, then press a new combination", "클릭한 뒤 새 조합을 누르세요"))
        self.recordHint = recordHint
        let shortcutRow = NSStackView(views: [shortcutLabel, recordButton, recordHint])
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .firstBaseline
        shortcutRow.spacing = 10

        let usage = AppAppearance.secondaryText(loc("Click a window's header to capture the whole window, or its body to capture just the content. Drag to select any area; press Esc or right-click to cancel.", "창의 헤더 위에서 클릭하면 창 전체를, 본문 위에서 클릭하면 본문만 캡처합니다. 드래그하면 원하는 영역을 고를 수 있고, Esc 또는 우클릭으로 취소합니다."))

        let sound = checkbox(loc("Play sound on capture", "캡처 시 소리 재생"), on: Settings.shared.playSound, action: #selector(toggleSound(_:)))
        let openLibrary = checkbox(loc("Open library after capture", "캡처 후 라이브러리 자동으로 열기"),
                                   on: Settings.shared.openLibraryAfterCapture, action: #selector(toggleOpenLibrary(_:)))
        let freeze = checkbox(loc("Freeze screen while capturing", "캡처 모드에서 화면 정지"),
                              detail: loc("Pick your area on a frozen snapshot of the screen and save exactly those pixels — even mid-video, the frame you aimed at is what you get.", "캡처 모드에 들어간 순간의 화면에서 영역을 고르고, 그 화면을 그대로 저장합니다. 영상이 재생 중이어도 조준한 프레임이 저장됩니다."),
                              on: Settings.shared.freezeScreenDuringCapture, action: #selector(toggleFreezeScreen(_:)))
        let launch = NSButton(checkboxWithTitle: loc("Launch at login", "macOS 로그인 시 자동 실행"), target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launch.state = LaunchAtLoginController.isEnabled ? .on : .off
        launchAtLoginCheck = launch

        return pane([banner, languageRow, shortcutRow, usage, sound, openLibrary, freeze, launch], spacing: 12)
    }

    // MARK: 저장
    private func buildStoragePane() -> NSView {
        let title = AppAppearance.sectionTitle(loc("Capture folder", "캡처 저장 폴더"))
        let path = NSPathControl()
        path.pathStyle = .standard
        path.url = Settings.shared.libraryDirectory
        path.isEditable = false
        path.target = self
        path.action = #selector(revealFolder)
        path.toolTip = loc("Click to open in Finder", "클릭하면 Finder에서 엽니다")
        path.font = .systemFont(ofSize: 12)
        path.translatesAutoresizingMaskIntoConstraints = false
        pathControl = path

        let choose = NSButton(title: loc("Choose Folder…", "폴더 선택…"), target: self, action: #selector(chooseFolder))
        let reset = NSButton(title: loc("Reset to Default", "기본값으로"), target: self, action: #selector(resetFolder))
        choose.bezelStyle = .rounded
        reset.bezelStyle = .rounded
        let buttons = NSStackView(views: [choose, reset])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let hint = AppAppearance.secondaryText(loc("New installs default to Application Support. If an older Desktop folder already exists, it is kept. Changing the folder does not move existing captures.", "새 설치의 기본 위치는 Application Support입니다. 예전 버전의 바탕화면 폴더가 이미 있으면 그대로 유지됩니다. 폴더를 바꿔도 기존 캡처는 옮겨지지 않습니다."))
        var content: [NSView] = [title, path, buttons, hint]
        if Settings.shared.libraryFolderNeedsRenewal {
            let warning = AppAppearance.secondaryText(loc("Access to your previous folder has expired. Choose it again to restore access to existing captures. New captures currently use the app’s default folder.",
                                                          "이전 폴더의 접근 권한을 복구하지 못했습니다. 폴더를 다시 선택하면 기존 캡처에 접근할 수 있습니다. 새 캡처는 현재 앱의 기본 폴더에 저장됩니다."))
            content.append(warning)
        }
        let container = pane(content, spacing: 10)
        path.widthAnchor.constraint(equalToConstant: 476).isActive = true
        return container
    }

    // MARK: 권한
    private func buildPermissionsPane() -> NSView {
        let screen = PermissionStatusRow(
            title: loc("Screen Recording", "화면 녹화"),
            detail: loc("Required for capturing. macOS grants it only with your consent; the app can only guide you to System Settings.", "캡처에 반드시 필요한 권한입니다. macOS가 사용자 동의로만 부여하며, 앱은 시스템 설정으로 안내할 수만 있습니다."))
        screen.addButton(loc("Open System Settings", "시스템 설정 열기"), target: self, action: #selector(openScreenCaptureSettings))
        #if !MAS
        screen.addButton(loc("Open Settings & Relaunch", "설정 열고 재시작"), target: self, action: #selector(openSettingsAndRelaunch))
        #endif
        screen.footnote = loc("After enabling the permission, a relaunch is sometimes needed. If capture is still blocked while the toggle is on, turn it off and on again, then relaunch.", "권한을 켠 뒤에는 앱을 다시 실행해야 반영되는 경우가 있습니다. 이미 켜져 있는데도 캡처가 막히면 토글을 껐다 켠 뒤 재시작하세요.")
        screenStatus = screen

        // MAS 판은 접근성 권한을 요청하지 않는다(심사 리젝 회피). 화면 녹화 권한만 노출한다.
        #if MAS
        return pane([screen], spacing: 12)
        #else
        let accessibility = PermissionStatusRow(
            title: loc("Window layout detection (optional)", "창 구조 인식 (선택 사항)"),
            detail: loc("When allowed, the accessibility structure that apps expose is used to precisely tell toolbars and tabs apart from content. Screen pixels, keystrokes, and document contents are never read.", "허용하면 브라우저·터미널 등 각 앱이 공개한 접근성 구조로 툴바/탭 영역과 본문을 정확히 구분합니다. 화면 픽셀·키 입력·문서 내용은 읽지 않습니다."))
        accessibility.addButton(loc("Request Permission", "권한 요청"), target: self, action: #selector(requestAccessibilityPermission))
        accessibility.addButton(loc("Open System Settings", "시스템 설정 열기"), target: self, action: #selector(openAccessibilitySettings))
        accessibilityStatus = accessibility

        return pane([screen, accessibility], spacing: 12)
        #endif
    }

    // MARK: 정보
    private func buildAboutPane() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let name = AppAppearance.title(Brand.name)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let versionLabel = AppAppearance.secondaryText(loc("Version \(version) (\(build)) · \(Brand.tagline)", "버전 \(version) (\(build)) · \(Brand.tagline)"), size: 12)
        let text = NSStackView(views: [name, versionLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let header = NSStackView(views: [icon, text])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        var actions: [NSView] = []
        #if !MAS
        let update = NSButton(title: loc("Check for Updates…", "업데이트 확인…"), target: UpdaterController.shared,
                              action: #selector(UpdaterController.checkForUpdates(_:)))
        update.bezelStyle = .rounded
        actions.append(update)
        #endif
        let welcome = NSButton(title: loc("Show Welcome Guide", "시작 안내 다시 보기"), target: self, action: #selector(showWelcome))
        welcome.bezelStyle = .rounded
        actions.append(welcome)
        let actionRow = NSStackView(views: actions)
        actionRow.orientation = .horizontal
        actionRow.spacing = 8

        let links = NSStackView(views: [
            linkButton("GitHub", url: "https://github.com/Canine89/oh-my-opensnap"),
            linkButton(loc("Report an Issue", "문제 신고 · 문의"), url: "https://github.com/Canine89/oh-my-opensnap/issues"),
            linkButton(loc("Privacy Policy", "개인정보 처리방침"), url: "https://github.com/Canine89/oh-my-opensnap/blob/main/PRIVACY.md")
        ])
        links.orientation = .horizontal
        links.spacing = 16

        return pane([header, actionRow, links], spacing: 16)
    }

    private func linkButton(_ title: String, url: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = .systemFont(ofSize: 12)
        button.toolTip = url
        button.identifier = NSUserInterfaceItemIdentifier(url)
        return button
    }

    // MARK: 단축키 레코더
    private func currentShortcutString() -> String {
        HotkeyFormatter.displayString(keyCode: Settings.shared.hotKeyCode,
                                      carbonModifiers: Settings.shared.hotKeyModifiers)
    }

    @objc private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        recordButton?.title = loc("Press keys…", "키 입력…")
        recordButton?.highlight(true)
        recordHint?.stringValue = loc("Press a new combination · Esc to cancel", "새 조합을 누르세요 · Esc로 취소")
        // 녹화 중에는 기존 전역 단축키를 잠시 끈다 — 안 그러면 현재 단축키(예: ⌘⇧2)를
        // 누를 때 녹화 대신 캡처가 실행돼 버린다.
        HotkeyManager.shared.suspend()
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // Esc → 취소
            if event.keyCode == 53 { self.stopRecording(); return nil }
            // 적어도 하나의 modifier 필요
            guard HotkeyFormatter.hasModifier(event.modifierFlags) else {
                self.recordHint?.stringValue = loc("Include at least one of ⌘ ⌥ ⌃ ⇧", "⌘ ⌥ ⌃ ⇧ 중 하나 이상과 함께 누르세요")
                return nil
            }

            Settings.shared.hotKeyCode = UInt32(event.keyCode)
            Settings.shared.hotKeyModifiers = HotkeyFormatter.carbonModifiers(from: event.modifierFlags)
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
            self.stopRecording()   // 새 설정으로 전역 단축키 재등록
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        recordButton?.highlight(false)
        recordButton?.title = currentShortcutString()
        recordHint?.stringValue = loc("Click, then press a new combination", "클릭한 뒤 새 조합을 누르세요")
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
            recordingMonitor = nil
        }
        // 전역 단축키 복구(녹화 중 변경됐으면 새 값으로 재등록).
        HotkeyManager.shared.reload()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        stopPermissionMonitor()
    }

    // MARK: 액션
    @objc private func toggleSound(_ sender: NSButton) {
        Settings.shared.playSound = (sender.state == .on)
    }

    @objc private func toggleOpenLibrary(_ sender: NSButton) {
        Settings.shared.openLibraryAfterCapture = (sender.state == .on)
    }

    @objc private func toggleFreezeScreen(_ sender: NSButton) {
        Settings.shared.freezeScreenDuringCapture = (sender.state == .on)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        do {
            try LaunchAtLoginController.setEnabled(sender.state == .on)
            refreshLaunchAtLoginState()
        } catch {
            refreshLaunchAtLoginState()
            showLaunchAtLoginError(error)
        }
    }

    @objc private func languagePicked(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0,
              sender.indexOfSelectedItem < AppLanguage.allCases.count else { return }
        Settings.shared.appLanguage = AppLanguage.allCases[sender.indexOfSelectedItem]
    }

    @objc private func goToPermissions() {
        tabs.selectedTabViewItemIndex = 2
    }

    @objc private func showWelcome() {
        NotificationCenter.default.post(name: .showWelcomeRequested, object: nil)
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginCheck?.state = LaunchAtLoginController.isEnabled ? .on : .off
    }

    private func startPermissionMonitor() {
        stopPermissionMonitor()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermissionStatus()
            }
        }
    }

    private func stopPermissionMonitor() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func refreshPermissionStatus() {
        let screenGranted = ScreenCapturePermission.isGranted
        permissionBanner?.isHidden = screenGranted
        screenStatus?.set(granted: screenGranted,
                          text: screenGranted ? loc("Granted", "허용됨") : loc("Required — allow it in System Settings before capturing", "필요함 — 캡처 전에 시스템 설정에서 허용하세요"))
        #if !MAS
        let axGranted = AccessibilityPermission.isGranted
        accessibilityStatus?.set(granted: axGranted,
                                 text: axGranted ? loc("Granted — per-app window structure tells headers from content", "허용됨 — 앱별 창 구조로 헤더와 본문을 구분합니다")
                                                 : loc("Not granted — per-app defaults are used instead", "미허용 — 앱별 기본 추정값을 사용합니다"),
                                 optional: true)
        #endif
    }

    @objc private func openScreenCaptureSettings() {
        ScreenCapturePermission.openSystemSettings()
    }

    #if !MAS
    @objc private func openSettingsAndRelaunch() {
        ScreenCapturePermission.openSystemSettings()
        AppRelauncher.relaunch()
    }
    #endif

    #if !MAS
    @objc private func requestAccessibilityPermission() {
        _ = AccessibilityPermission.request()
        refreshPermissionStatus()
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityPermission.openSystemSettings()
    }
    #endif

    private func showLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = loc("Could not change the launch-at-login setting.", "자동 실행 설정을 변경하지 못했습니다.")
        alert.informativeText = loc("Run the app from the Applications folder and try again.", "앱을 Applications 폴더에서 실행한 뒤 다시 시도하세요.") + "\n\n\(error.localizedDescription)"
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Settings.shared.libraryDirectory])
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = loc("Save to This Folder", "이 폴더에 저장")
        panel.directoryURL = Settings.shared.libraryDirectory
        if panel.runModal() == .OK, let url = panel.url {
            do { try Settings.shared.setLibraryDirectory(url) }
            catch {
                OperationErrorPresenter.show(error, action: loc("Could not access the selected folder", "선택한 폴더의 접근 권한을 저장하지 못했습니다"))
                return
            }
            pathControl?.url = url
            CaptureLibrary.shared.directoryDidChange()
        }
    }

    @objc private func resetFolder() {
        Settings.shared.resetLibraryDirectory()
        pathControl?.url = Settings.shared.libraryDirectory
        CaptureLibrary.shared.directoryDidChange()
    }
}

/// 권한 하나의 카드: 상태 점 + 제목 + 설명 + 버튼들 + 각주.
private final class PermissionStatusRow: NSVisualEffectView {
    private let dot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private let footnoteLabel = AppAppearance.secondaryText("")
    private let stack = NSStackView()

    var footnote: String = "" {
        didSet {
            footnoteLabel.stringValue = footnote
            footnoteLabel.isHidden = footnote.isEmpty
        }
    }

    init(title: String, detail: String) {
        super.init(frame: .zero)
        material = .contentBackground
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Brand.cornerRadius
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let titleLabel = AppAppearance.sectionTitle(title)
        let titleRow = NSStackView(views: [dot, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let detailLabel = AppAppearance.secondaryText(detail)

        buttons.orientation = .horizontal
        buttons.spacing = 8

        footnoteLabel.isHidden = true
        footnoteLabel.textColor = .tertiaryLabelColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 15, bottom: 14, right: 15)
        stack.translatesAutoresizingMaskIntoConstraints = false
        [titleRow, statusLabel, detailLabel, buttons, footnoteLabel].forEach(stack.addArrangedSubview)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -30),
            footnoteLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -30)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addButton(_ title: String, target: AnyObject, action: Selector) {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        buttons.addArrangedSubview(button)
    }

    func set(granted: Bool, text: String, optional: Bool = false) {
        let color: NSColor = granted ? .systemGreen : (optional ? .systemGray : .systemOrange)
        dot.layer?.backgroundColor = color.cgColor
        statusLabel.stringValue = text
        statusLabel.textColor = granted ? .systemGreen : (optional ? .secondaryLabelColor : .systemOrange)
    }
}
