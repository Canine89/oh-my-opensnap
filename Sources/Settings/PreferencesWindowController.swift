import AppKit

/// 환경설정 창: 단축키 / 사운드 / 로그인 실행 / 라이브러리 / 화면 녹화 권한.
@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var pathLabel: NSTextField?
    private var recordButton: NSButton?
    private var launchAtLoginCheck: NSButton?
    private var permissionStatusLabel: NSTextField?
    private var permissionTimer: Timer?
    private var recordingMonitor: Any?
    private var isRecording = false

    func showWindow() {
        if window == nil { buildWindow() }
        refreshLaunchAtLoginState()
        refreshPermissionStatus()
        startPermissionMonitor()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 480, height: 420)
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "\(Brand.name) 설정"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 단축키 레코더
        let shortcutRow = NSStackView()
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 8
        let shortcutLabel = NSTextField(labelWithString: "캡처 단축키")
        let recordButton = NSButton(title: currentShortcutString(),
                                    target: self, action: #selector(toggleRecording))
        recordButton.bezelStyle = .rounded
        recordButton.setButtonType(.momentaryPushIn)
        recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        self.recordButton = recordButton
        shortcutRow.addArrangedSubview(shortcutLabel)
        shortcutRow.addArrangedSubview(recordButton)

        let soundCheck = NSButton(checkboxWithTitle: "캡처 시 소리 재생",
                                  target: self, action: #selector(toggleSound(_:)))
        soundCheck.state = Settings.shared.playSound ? .on : .off

        let openLibraryCheck = NSButton(checkboxWithTitle: "캡처 후 라이브러리 자동으로 열기",
                                        target: self, action: #selector(toggleOpenLibrary(_:)))
        openLibraryCheck.state = Settings.shared.openLibraryAfterCapture ? .on : .off

        let launchAtLoginCheck = NSButton(checkboxWithTitle: "macOS 로그인 시 자동 실행",
                                          target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchAtLoginCheck.state = LaunchAtLoginController.isEnabled ? .on : .off
        self.launchAtLoginCheck = launchAtLoginCheck

        let folderRow = NSStackView()
        folderRow.orientation = .horizontal
        folderRow.spacing = 8
        let chooseButton = NSButton(title: "저장 폴더 선택…", target: self, action: #selector(chooseFolder))
        let resetButton = NSButton(title: "기본값", target: self, action: #selector(resetFolder))
        let label = NSTextField(labelWithString: Settings.shared.libraryDirectory.path)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel = label
        folderRow.addArrangedSubview(chooseButton)
        folderRow.addArrangedSubview(resetButton)
        folderRow.addArrangedSubview(label)

        let folderHint = NSTextField(wrappingLabelWithString: "새 설치의 기본 저장 위치는 Application Support입니다. 바탕화면 폴더가 이미 있으면 그대로 유지됩니다.")
        folderHint.font = .systemFont(ofSize: 11)
        folderHint.textColor = .tertiaryLabelColor

        // 화면 녹화 권한
        let permissionTitle = NSTextField(labelWithString: "화면 녹화 권한")
        permissionTitle.font = .boldSystemFont(ofSize: 12)

        let permissionStatus = NSTextField(labelWithString: "")
        permissionStatus.font = .systemFont(ofSize: 12)
        permissionStatusLabel = permissionStatus

        let permissionRow = NSStackView()
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 8
        let openSettingsButton = NSButton(title: "시스템 설정 열기",
                                          target: self, action: #selector(openScreenCaptureSettings))
        openSettingsButton.bezelStyle = .rounded
        let quitHintButton = NSButton(title: "설정 열고 앱 종료",
                                      target: self, action: #selector(openSettingsAndQuit))
        quitHintButton.bezelStyle = .rounded
        permissionRow.addArrangedSubview(openSettingsButton)
        permissionRow.addArrangedSubview(quitHintButton)

        let permissionHint = NSTextField(wrappingLabelWithString: "권한을 켠 뒤에는 앱을 다시 실행해야 macOS가 반영하는 경우가 있습니다. 이미 켜져 있는데도 캡처가 막히면 토글을 한 번 끄고 다시 켠 뒤 재실행하세요.")
        permissionHint.font = .systemFont(ofSize: 11)
        permissionHint.textColor = .secondaryLabelColor

        let hint = NSTextField(wrappingLabelWithString: "윈도우 위에서 클릭하면 해당 윈도우를, 드래그하면 지정 영역을 캡처합니다(취소는 Esc 또는 우클릭). 캡처 이미지는 클립보드에 복사되고 위 저장 폴더에 보관됩니다.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        stack.addArrangedSubview(shortcutRow)
        stack.addArrangedSubview(soundCheck)
        stack.addArrangedSubview(openLibraryCheck)
        stack.addArrangedSubview(launchAtLoginCheck)
        stack.addArrangedSubview(folderRow)
        stack.addArrangedSubview(folderHint)
        stack.addArrangedSubview(permissionTitle)
        stack.addArrangedSubview(permissionStatus)
        stack.addArrangedSubview(permissionRow)
        stack.addArrangedSubview(permissionHint)
        stack.addArrangedSubview(hint)

        let content = NSView(frame: contentRect)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        window.contentView = content
        self.window = window
        refreshPermissionStatus()
    }

    private func currentShortcutString() -> String {
        HotkeyFormatter.displayString(keyCode: Settings.shared.hotKeyCode,
                                      carbonModifiers: Settings.shared.hotKeyModifiers)
    }

    @objc private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        recordButton?.title = "키 입력…"
        recordButton?.highlight(true)
        // 녹화 중에는 기존 전역 단축키를 잠시 끈다 — 안 그러면 현재 단축키(예: ⌘⇧2)를
        // 누를 때 녹화 대신 캡처가 실행돼 버린다.
        HotkeyManager.shared.suspend()
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // Esc → 취소
            if event.keyCode == 53 { self.stopRecording(); return nil }
            // 적어도 하나의 modifier 필요
            guard HotkeyFormatter.hasModifier(event.modifierFlags) else { return nil }

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

    @objc private func toggleSound(_ sender: NSButton) {
        Settings.shared.playSound = (sender.state == .on)
    }

    @objc private func toggleOpenLibrary(_ sender: NSButton) {
        Settings.shared.openLibraryAfterCapture = (sender.state == .on)
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
        if ScreenCapturePermission.isGranted {
            permissionStatusLabel?.stringValue = "상태: 허용됨"
            permissionStatusLabel?.textColor = .systemGreen
        } else {
            permissionStatusLabel?.stringValue = "상태: 필요함 — 캡처 전에 시스템 설정에서 허용하세요"
            permissionStatusLabel?.textColor = .systemOrange
        }
    }

    @objc private func openScreenCaptureSettings() {
        ScreenCapturePermission.openSystemSettings()
    }

    @objc private func openSettingsAndQuit() {
        ScreenCapturePermission.openSystemSettings()
        NSApp.terminate(nil)
    }

    private func showLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "자동 실행 설정을 변경하지 못했습니다."
        alert.informativeText = "앱을 Applications 폴더에서 실행한 뒤 다시 시도하세요.\n\n\(error.localizedDescription)"
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "이 폴더에 저장"
        panel.directoryURL = Settings.shared.libraryDirectory
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.libraryDirectory = url
            pathLabel?.stringValue = url.path
            CaptureLibrary.shared.directoryDidChange()
        }
    }

    @objc private func resetFolder() {
        Settings.shared.resetLibraryDirectory()
        pathLabel?.stringValue = Settings.shared.libraryDirectory.path
        CaptureLibrary.shared.directoryDidChange()
    }
}
