import Foundation

/// UserDefaults 기반 환경설정.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard
    private init() {}

    private enum Keys {
        static let saveToFile = "saveToFile"
        static let playSound = "playSound"
        static let saveDirectory = "saveDirectoryBookmark"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
    }

    /// 전역 단축키 (Carbon 키코드 + Carbon modifier 마스크).
    /// 기본값: ⌘⇧2  (cmd + shift + 2)
    var hotKeyCode: UInt32 {
        get {
            let stored = defaults.object(forKey: Keys.hotKeyCode) as? Int
            return UInt32(stored ?? 19)        // kVK_ANSI_2 == 19
        }
        set { defaults.set(Int(newValue), forKey: Keys.hotKeyCode) }
    }

    var hotKeyModifiers: UInt32 {
        get {
            let stored = defaults.object(forKey: Keys.hotKeyModifiers) as? Int
            return UInt32(stored ?? (256 | 512))   // cmdKey | shiftKey
        }
        set { defaults.set(Int(newValue), forKey: Keys.hotKeyModifiers) }
    }

    /// 클립보드 복사는 항상 수행 (요청 핵심 기능). 파일 저장은 옵션.
    var saveToFile: Bool {
        get { defaults.bool(forKey: Keys.saveToFile) }
        set { defaults.set(newValue, forKey: Keys.saveToFile) }
    }

    var playSound: Bool {
        get { defaults.object(forKey: Keys.playSound) == nil ? true : defaults.bool(forKey: Keys.playSound) }
        set { defaults.set(newValue, forKey: Keys.playSound) }
    }

    var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: Keys.saveDirectory) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set { defaults.set(newValue.path, forKey: Keys.saveDirectory) }
    }
}
