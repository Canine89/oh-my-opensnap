import Foundation

/// UserDefaults 기반 환경설정.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard
    private init() {}

    private enum Keys {
        static let playSound = "playSound"
        static let libraryDirectory = "libraryDirectoryPath"
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

    var playSound: Bool {
        get { defaults.object(forKey: Keys.playSound) == nil ? true : defaults.bool(forKey: Keys.playSound) }
        set { defaults.set(newValue, forKey: Keys.playSound) }
    }

    /// 캡처본 저장(라이브러리) 폴더. 기본값은 바탕화면/oh-my-opensnap,
    /// 사용자가 직접 고르면 그 폴더로 바뀐다.
    var libraryDirectory: URL {
        get {
            if let path = defaults.string(forKey: Keys.libraryDirectory) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return Self.defaultLibraryDirectory
        }
        set { defaults.set(newValue.path, forKey: Keys.libraryDirectory) }
    }

    /// 사용자가 폴더를 직접 지정했는지.
    var hasCustomLibraryDirectory: Bool {
        defaults.string(forKey: Keys.libraryDirectory) != nil
    }

    /// 저장 폴더를 기본값(바탕화면/oh-my-opensnap)으로 되돌린다.
    func resetLibraryDirectory() {
        defaults.removeObject(forKey: Keys.libraryDirectory)
    }

    /// 기본 저장 폴더: 바탕화면/oh-my-opensnap.
    static var defaultLibraryDirectory: URL {
        let base = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(Brand.folderName, isDirectory: true)
    }
}
