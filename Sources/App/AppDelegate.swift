import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var preparingToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        menuBar = MenuBarController()

        // 전역 단축키(기본 ⌘⇧2) → 캡처 진입. 접근성 권한 불필요, 샌드박스 호환.
        HotkeyManager.shared.onTrigger = {
            CaptureCoordinator.shared.startAreaCapture()
        }
        HotkeyManager.shared.start()

        #if DEBUG
        // 개발용: `-SnapshotLibraryTo /path.png` 로 실행하면 라이브러리 창을 그려 PNG로 저장하고 종료한다.
        // (화면 녹화 권한 없이 뷰 계층만 렌더 — 레이아웃·간격·아이콘 검토용)
        if let path = UserDefaults.standard.string(forKey: "SnapshotLibraryTo") {
            LibraryWindowController.shared.showWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                LibraryWindowController.shared.debugSnapshot(to: path) {
                    NSApp.terminate(nil)
                }
            }
        }
        // 개발용: `-SnapshotChoiceHUDTo /path.png` 로 실행하면 선택 HUD(창 스냅 예시)를 PNG로 저장하고 종료한다.
        if let path = UserDefaults.standard.string(forKey: "SnapshotChoiceHUDTo") {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let anchor = CGRect(x: visible.midX - 360, y: visible.midY - 60, width: 720, height: 420)
            var context = CaptureChoiceHUD.Context.area(anchor, scale: 2)   // Retina 표기(2× 칩)까지 검토

            if UserDefaults.standard.bool(forKey: "SnapshotChoiceHUDWindow") {
                context.appName = "Safari"
                context.appIcon = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
                context.zone = loc("Entire window", "창 전체")
            }
            let hud = CaptureChoiceHUD(anchor: anchor, context: context, onImage: {}, onVideo: {}, onCancel: {})
            debugChoiceHUD = hud
            hud.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Task { @MainActor in
                    await hud.debugSnapshot(to: path)
                    NSApp.terminate(nil)
                }
            }
        }
        #endif
    }

    #if DEBUG
    private var debugChoiceHUD: CaptureChoiceHUD?
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !preparingToTerminate else { return .terminateLater }
        preparingToTerminate = true
        CaptureCoordinator.shared.isSuspended = true
        OverlayController.shared.cancelForTermination()
        LibraryWindowController.shared.flushPendingEdits()
        Task { @MainActor in
            do {
                await OverlayController.shared.finishPendingCaptures()
                try await VideoRecordingController.shared.finishForTermination()
                await CaptureOutput.flush()
                await VideoExportService.flush()
                // 인코딩 완료 중 추가된 편집 저장까지 다시 예약한 뒤 큐를 비운다.
                LibraryWindowController.shared.flushPendingEdits()
                try await CaptureLibrary.shared.flush()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                preparingToTerminate = false
                CaptureCoordinator.shared.isSuspended = false
                sender.reply(toApplicationShouldTerminate: false)
                OperationErrorPresenter.show(error, action: loc("Could not finish saving. The app remains open.",
                                                               "저장을 완료하지 못해 앱을 열어 두었습니다."))
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.stop()
    }

    /// 편집 단축키(⌘Z/⌘C)와 창 단축키(⌘W/⌘M)가 first responder로 라우팅되도록 표준 Edit/Window 메뉴를 둔다.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: loc("Quit \(Brand.name)", "\(Brand.name) 종료"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: loc("Edit", "편집"))
        editMenu.addItem(withTitle: loc("Undo", "되돌리기"), action: #selector(EditorImageView.undo(_:)), keyEquivalent: "z")
        editMenu.addItem(withTitle: loc("Redo", "다시 실행"), action: #selector(EditorImageView.redo(_:)), keyEquivalent: "Z")   // 대문자 = ⇧⌘Z
        editMenu.addItem(withTitle: loc("Copy", "복사"), action: #selector(EditorImageView.copy(_:)), keyEquivalent: "c")
        editItem.submenu = editMenu

        // 라이브러리·설정 창을 ⌘W로 닫고 ⌘M으로 최소화할 수 있도록 표준 Window 메뉴를 둔다.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: loc("Window", "윈도우"))
        windowMenu.addItem(withTitle: loc("Close", "닫기"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: loc("Minimize", "최소화"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // 메뉴바 앱이므로 마지막 윈도우가 닫혀도 종료하지 않는다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
