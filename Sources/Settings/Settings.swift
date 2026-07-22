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
        static let libraryDirectoryBookmark = "libraryDirectoryBookmark"
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
            #if MAS
            return masLibraryDirectory()
            #else
            if let path = defaults.string(forKey: Keys.libraryDirectory) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return Self.defaultLibraryDirectory
            #endif
        }
        set {
            defaults.set(newValue.path, forKey: Keys.libraryDirectory)
            #if MAS
            bookmarkLock.lock()
            defer { bookmarkLock.unlock() }
            if let data = try? newValue.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) {
                defaults.set(data, forKey: Keys.libraryDirectoryBookmark)
            } else {
                defaults.removeObject(forKey: Keys.libraryDirectoryBookmark)
            }
            scopedLibraryURL?.stopAccessingSecurityScopedResource()
            scopedLibraryURL = resolveLibraryBookmarkLocked()
            didResolveBookmark = true
            #endif
        }
    }

    #if MAS
    // 샌드박스: 컨테이너 밖 폴더는 security-scoped bookmark로만 접근이 유지된다.
    // 이 getter는 캡처 저장(ioQueue)과 설정 창(메인)에서 동시에 불리므로
    // 북마크 상태는 전부 bookmarkLock 아래에서만 만진다.
    private let bookmarkLock = NSLock()
    /// 현재 security scope를 연 채 유지 중인 URL. 앱 수명 동안 접근을 붙잡아 둔다.
    private var scopedLibraryURL: URL?
    private var didResolveBookmark = false

    private func masLibraryDirectory() -> URL {
        bookmarkLock.lock()
        defer { bookmarkLock.unlock() }
        if !didResolveBookmark {
            scopedLibraryURL = resolveLibraryBookmarkLocked()
            didResolveBookmark = true
        }
        if let url = scopedLibraryURL { return url }
        // 북마크가 없거나 해석 실패(폴더 삭제·볼륨 분리 등): 저장된 raw path는
        // 샌드박스에서 접근 불가이므로 항상 컨테이너 기본 폴더로 폴백한다.
        return Self.defaultLibraryDirectory
    }

    /// bookmarkLock을 잡은 상태에서만 호출. 북마크를 해석해 scope를 열고 URL을 돌려준다.
    private func resolveLibraryBookmarkLocked() -> URL? {
        guard let data = defaults.data(forKey: Keys.libraryDirectoryBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) {
            defaults.set(fresh, forKey: Keys.libraryDirectoryBookmark)
        }
        return url
    }
    #endif

    /// 사용자가 폴더를 직접 지정했는지.
    var hasCustomLibraryDirectory: Bool {
        defaults.string(forKey: Keys.libraryDirectory) != nil
    }

    /// 저장 폴더를 기본값으로 되돌린다.
    func resetLibraryDirectory() {
        defaults.removeObject(forKey: Keys.libraryDirectory)
        #if MAS
        bookmarkLock.lock()
        defer { bookmarkLock.unlock() }
        defaults.removeObject(forKey: Keys.libraryDirectoryBookmark)
        scopedLibraryURL?.stopAccessingSecurityScopedResource()
        scopedLibraryURL = nil
        didResolveBookmark = true
        #endif
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
