import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private var prefs: PreferencesWindowController?
    private var welcome: WelcomePopover?
    private var captureItem: NSMenuItem?
    private var pauseVideoItem: NSMenuItem?
    private var stopVideoItem: NSMenuItem?

    // 녹화 경과 시간을 상태 아이콘 옆에 표시하기 위한 상태
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    private static let idleImage: NSImage? = {
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "\(Brand.name) 화면 캡처")
        image?.isTemplate = true
        return image
    }()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = Self.idleImage
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem.sectionHeader(title: Brand.name))
        captureItem = addItem(to: menu, title: "캡처", action: #selector(captureArea))
        pauseVideoItem = addItem(to: menu, title: pauseVideoTitle(), action: #selector(toggleVideoPause))
        stopVideoItem = addItem(to: menu, title: "촬영 중지", action: #selector(stopVideo))
        addItem(to: menu, title: "라이브러리…", action: #selector(openLibrary), key: "l")
        menu.addItem(.separator())
        addItem(to: menu, title: "설정…", action: #selector(openPreferences), key: ",")
        #if !MAS
        // Sparkle 업데이트 확인 (타깃은 UpdaterController) — MAS 판은 App Store가 업데이트를 맡는다.
        let updateItem = NSMenuItem(title: "업데이트 확인…",
                                    action: #selector(UpdaterController.checkForUpdates(_:)),
                                    keyEquivalent: "")
        updateItem.target = UpdaterController.shared
        menu.addItem(updateItem)
        #endif
        addItem(to: menu, title: "시작 안내…", action: #selector(showWelcome))
        menu.addItem(.separator())
        addItem(to: menu, title: "\(Brand.name) 종료", action: #selector(quit), key: "q")
        statusItem.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(refreshShortcut),
                                               name: .hotkeyChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshVideoState),
                                               name: .videoRecordingStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showWelcome),
                                               name: .showWelcomeRequested, object: nil)
        refreshShortcut()
        refreshVideoState()

        // 첫 실행: Dock 아이콘이 없어 "실행됐는지"조차 알기 어렵다 → 아이콘에서 안내를 뻗어 보여 준다.
        if !WelcomePopover.wasShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showWelcome()
            }
        }
    }

    private func pauseVideoTitle() -> String {
        VideoRecordingController.shared.isPaused ? "촬영 재개" : "촬영 일시정지"
    }

    /// 단축키를 공백으로 흉내내지 않고 메뉴가 원래 그리는 자리(오른쪽 정렬)에 표시한다.
    @objc private func refreshShortcut() {
        guard let captureItem else { return }
        let code = Settings.shared.hotKeyCode
        let mods = Settings.shared.hotKeyModifiers
        if let equivalent = HotkeyFormatter.menuKeyEquivalent(keyCode: code, carbonModifiers: mods) {
            captureItem.title = "캡처"
            captureItem.keyEquivalent = equivalent.key
            captureItem.keyEquivalentModifierMask = equivalent.modifiers
        } else {
            captureItem.title = "캡처   \(HotkeyFormatter.displayString(keyCode: code, carbonModifiers: mods))"
            captureItem.keyEquivalent = ""
        }
    }

    @objc private func refreshVideoState() {
        let controller = VideoRecordingController.shared
        let isRecording = controller.isRecording
        pauseVideoItem?.title = pauseVideoTitle()
        pauseVideoItem?.isEnabled = isRecording
        pauseVideoItem?.isHidden = !isRecording
        stopVideoItem?.isEnabled = isRecording
        stopVideoItem?.isHidden = !isRecording

        if isRecording {
            if recordingStartedAt == nil {
                recordingStartedAt = Date()
                pausedTotal = 0
                pausedAt = nil
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateRecordingBadge() }
                }
            }
            if controller.isPaused, pausedAt == nil {
                pausedAt = Date()
            } else if !controller.isPaused, let paused = pausedAt {
                pausedTotal += Date().timeIntervalSince(paused)
                pausedAt = nil
            }
            updateRecordingBadge()
        } else {
            recordingTimer?.invalidate()
            recordingTimer = nil
            recordingStartedAt = nil
            pausedAt = nil
            pausedTotal = 0
            statusItem.button?.image = Self.idleImage
            statusItem.button?.title = ""
        }
    }

    /// 녹화 중: 빨간 점(일시정지면 ⏸) + 경과 시간. 바닥 HUD를 놓쳐도 메뉴 막대에서 상태가 보인다.
    private func updateRecordingBadge() {
        guard let button = statusItem.button, let startedAt = recordingStartedAt else { return }
        let paused = VideoRecordingController.shared.isPaused
        let reference = pausedAt ?? Date()
        let elapsed = max(0, reference.timeIntervalSince(startedAt) - pausedTotal)
        let total = Int(elapsed)
        button.title = String(format: " %02d:%02d", total / 60, total % 60)
        let symbol = paused ? "pause.circle.fill" : "record.circle.fill"
        let config = NSImage.SymbolConfiguration(paletteColors: [paused ? .secondaryLabelColor : Brand.red])
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: paused ? "촬영 일시정지" : "촬영 중")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        button.image = image
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func captureArea() {
        CaptureCoordinator.shared.startAreaCapture()
    }

    @objc private func toggleVideoPause() {
        VideoRecordingController.shared.togglePause()
    }

    @objc private func stopVideo() {
        VideoRecordingController.shared.stop()
    }

    @objc private func openPreferences() {
        if prefs == nil { prefs = PreferencesWindowController() }
        prefs?.showWindow()
    }

    @objc private func openLibrary() {
        LibraryWindowController.shared.showWindow()
    }

    @objc private func showWelcome() {
        guard let button = statusItem.button else { return }
        if welcome == nil { welcome = WelcomePopover() }
        welcome?.show(relativeTo: button)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshVideoState()
    }
}
