import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private var prefs: PreferencesWindowController?
    private var captureItem: NSMenuItem?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "\(Brand.name) 화면 캡처")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let header = NSMenuItem(title: "\(Brand.name) · \(Brand.tagline)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        captureItem = addItem(to: menu, title: captureTitle(), action: #selector(captureArea))
        addItem(to: menu, title: "라이브러리…", action: #selector(openLibrary), key: "l")
        menu.addItem(.separator())
        addItem(to: menu, title: "설정…", action: #selector(openPreferences), key: ",")
        menu.addItem(.separator())
        addItem(to: menu, title: "\(Brand.name) 종료", action: #selector(quit), key: "q")
        statusItem.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(refreshShortcut),
                                               name: .hotkeyChanged, object: nil)
    }

    private func captureTitle() -> String {
        let shortcut = HotkeyFormatter.displayString(keyCode: Settings.shared.hotKeyCode,
                                                     carbonModifiers: Settings.shared.hotKeyModifiers)
        return "캡처   \(shortcut)"
    }

    @objc private func refreshShortcut() {
        captureItem?.title = captureTitle()
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

    @objc private func openPreferences() {
        if prefs == nil { prefs = PreferencesWindowController() }
        prefs?.showWindow()
    }

    @objc private func openLibrary() {
        LibraryWindowController.shared.showWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
