import Foundation

/// UserDefaults 기반 환경설정.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard
    private init() {}

    private enum Keys {
        static let playSound = "playSound"
        static let openLibraryAfterCapture = "openLibraryAfterCapture"
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

    /// 캡처 직후 라이브러리 창을 자동으로 열지. 기본값 true(기존 동작).
    var openLibraryAfterCapture: Bool {
        get {
            defaults.object(forKey: Keys.openLibraryAfterCapture) == nil
                ? true
                : defaults.bool(forKey: Keys.openLibraryAfterCapture)
        }
        set { defaults.set(newValue, forKey: Keys.openLibraryAfterCapture) }
    }

    /// 캡처본 저장(라이브러리) 폴더.
    /// 기본값은 Application Support(바탕화면 TCC 회피). 이미 바탕화면 폴더가 있으면 그걸 유지한다.
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

    /// 저장 폴더를 기본값으로 되돌린다.
    func resetLibraryDirectory() {
        defaults.removeObject(forKey: Keys.libraryDirectory)
    }

    /// 신규 설치: Application Support/oh-my-opensnap.
    /// 기존에 바탕화면 라이브러리가 있으면 그대로 써서 캡처본이 사라지지 않게 한다.
    static var defaultLibraryDirectory: URL {
        let desktop = (FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent(Brand.folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: desktop.path) {
            return desktop
        }
        return preferredLibraryDirectory
    }

    /// 바탕화면 TCC를 피한 권장 기본 경로.
    static var preferredLibraryDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(Brand.folderName, isDirectory: true)
    }
}
