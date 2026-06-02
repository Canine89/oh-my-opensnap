import AppKit

/// 최소 환경설정 창: 파일 저장 토글 / 저장 폴더 / 사운드 토글.
@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var pathLabel: NSTextField?
    private var recordButton: NSButton?
    private var recordingMonitor: Any?
    private var isRecording = false

    func showWindow() {
        if window == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 440, height: 260)
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

        let saveCheck = NSButton(checkboxWithTitle: "클립보드 복사와 함께 파일로 저장",
                                 target: self, action: #selector(toggleSave(_:)))
        saveCheck.state = Settings.shared.saveToFile ? .on : .off

        let folderRow = NSStackView()
        folderRow.orientation = .horizontal
        folderRow.spacing = 8
        let chooseButton = NSButton(title: "저장 폴더 선택…", target: self, action: #selector(chooseFolder))
        let label = NSTextField(labelWithString: Settings.shared.saveDirectory.path)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel = label
        folderRow.addArrangedSubview(chooseButton)
        folderRow.addArrangedSubview(label)

        let hint = NSTextField(wrappingLabelWithString: "윈도우 위에서 클릭하면 해당 윈도우를, 드래그하면 지정 영역을 캡처합니다. 캡처 후 이미지는 자동으로 클립보드에 복사됩니다.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        stack.addArrangedSubview(shortcutRow)
        stack.addArrangedSubview(soundCheck)
        stack.addArrangedSubview(saveCheck)
        stack.addArrangedSubview(folderRow)
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
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // Esc → 취소
            if event.keyCode == 53 { self.stopRecording(); return nil }
            // 적어도 하나의 modifier 필요
            guard HotkeyFormatter.hasModifier(event.modifierFlags) else { return nil }

            Settings.shared.hotKeyCode = UInt32(event.keyCode)
            Settings.shared.hotKeyModifiers = HotkeyFormatter.carbonModifiers(from: event.modifierFlags)
            HotkeyManager.shared.reload()
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
            self.stopRecording()
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
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
    }

    @objc private func toggleSound(_ sender: NSButton) {
        Settings.shared.playSound = (sender.state == .on)
    }

    @objc private func toggleSave(_ sender: NSButton) {
        Settings.shared.saveToFile = (sender.state == .on)
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Settings.shared.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.saveDirectory = url
            pathLabel?.stringValue = url.path
        }
    }
}
