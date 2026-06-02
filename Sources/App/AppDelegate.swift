import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        menuBar = MenuBarController()

        // 전역 단축키(기본 ⌘⇧2) → 캡처 진입. 접근성 권한 불필요, 샌드박스 호환.
        HotkeyManager.shared.onTrigger = {
            CaptureCoordinator.shared.startAreaCapture()
        }
        HotkeyManager.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.stop()
    }

    /// 편집 단축키(⌘Z/⌘C)가 first responder로 라우팅되도록 표준 Edit 메뉴를 둔다.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "\(Brand.name) 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "되돌리기", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "복사", action: Selector(("copy:")), keyEquivalent: "c")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // 메뉴바 앱이므로 마지막 윈도우가 닫혀도 종료하지 않는다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
