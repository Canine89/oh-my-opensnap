import AppKit
import ImageIO

struct LibraryItem {
    let url: URL
    let date: Date
}

extension Notification.Name {
    static let libraryDidChange = Notification.Name("com.goldenrabbit.appresizer.libraryDidChange")
}

/// 캡처본을 바탕화면 `oh-my-opensnap` 폴더에 영구 보관하고 목록을 제공한다.
/// 사용자의 '저장 폴더' 옵션과는 별개의 라이브러리 저장소.
///
/// ⚠️ macOS 26(Tahoe)에서 바탕화면은 TCC 보호 폴더라, 첫 접근 시 "바탕화면 접근"
/// 동의창이 뜬다. 이 동의 검사는 호출 스레드를 블로킹하므로, **모든 디스크 I/O를
/// 메인 스레드가 아닌 `ioQueue`에서** 수행한다. (메인에서 하면 동의창이 떠 있는 동안
/// 런루프가 멈춰 무한 바람개비가 된다.)
final class CaptureLibrary {
    static let shared = CaptureLibrary()

    /// 현재 저장 폴더. 사용자가 설정에서 고른 폴더(기본값: 바탕화면/oh-my-opensnap).
    var directory: URL { Settings.shared.libraryDirectory }
    /// thumbnailCache 는 메인 스레드에서만 읽고 쓴다.
    private var thumbnailCache: [URL: NSImage] = [:]
    /// 바탕화면(TCC 보호) 디스크 I/O를 메인 런루프 밖에서 직렬 수행.
    private let ioQueue = DispatchQueue(label: "com.goldenrabbit.ohmyopensnap.library.io", qos: .userInitiated)

    private init() {
        // 디렉터리 생성 + 레거시 이관은 바탕화면 접근이라 백그라운드에서.
        let dir = directory
        ioQueue.async { [weak self] in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self?.migrateLegacyIfNeeded()
        }
    }

    /// 저장 폴더가 바뀌었을 때 호출 — 새 폴더를 만들고 목록 갱신 알림을 보낸다.
    func directoryDidChange() {
        let dir = directory
        ioQueue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            }
        }
    }

    /// 파일명 타임스탬프 (yyyy-MM-dd-HH-mm-ss).
    private func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: date)
    }

    /// 충돌을 피한 PNG 대상 URL. (ioQueue에서 호출)
    private func uniqueURL(for date: Date) -> URL {
        let base = fileName(for: date)
        var url = directory.appendingPathComponent(base + ".png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(suffix).png")
            suffix += 1
        }
        return url
    }

    /// 캡처본 저장 후 변경 알림 발송. 디스크 쓰기는 백그라운드에서 수행하고
    /// 알림만 메인으로 되돌린다.
    func save(pngData: Data, date: Date) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let url = self.uniqueURL(for: date)
            do {
                try pngData.write(to: url)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                }
            } catch {
                NSLog("Library save failed: \(error)")
            }
        }
    }

    /// 이전 보관 위치(구 AppResizer 폴더들)의 PNG를 새 폴더로 이관. (ioQueue에서 호출)
    private func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        var legacyDirs: [URL] = []
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            legacyDirs.append(appSupport.appendingPathComponent("AppResizer/Library", isDirectory: true))
        }
        if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            legacyDirs.append(desktop.appendingPathComponent("AppResizer", isDirectory: true))
            legacyDirs.append(desktop.appendingPathComponent("oh-my-snap", isDirectory: true))   // 구 앱 이름 폴더
        }

        for legacy in legacyDirs {
            guard fm.fileExists(atPath: legacy.path), legacy != directory else { continue }
            let urls = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for old in urls where old.pathExtension.lowercased() == "png" {
                let date = (try? old.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                try? fm.moveItem(at: old, to: uniqueURL(for: date))
            }
            try? fm.removeItem(at: legacy)
        }
    }

    /// 최신순 목록을 백그라운드에서 읽어 메인에서 콜백한다.
    func loadItems(completion: @escaping ([LibraryItem]) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let keys: Set<URLResourceKey> = [.creationDateKey]
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: self.directory, includingPropertiesForKeys: Array(keys))) ?? []
            let items = urls
                .filter { $0.pathExtension.lowercased() == "png" }
                .map { url -> LibraryItem in
                    let date = (try? url.resourceValues(forKeys: keys).creationDate) ?? .distantPast
                    return LibraryItem(url: url, date: date)
                }
                .sorted { $0.date > $1.date }
            DispatchQueue.main.async { completion(items) }
        }
    }

    /// 파일이 덮어써졌을 때 캐시된 썸네일을 버린다. (메인)
    func invalidateThumbnail(for url: URL) {
        thumbnailCache[url] = nil
    }

    /// 휴지통으로 이동(바탕화면 접근)도 백그라운드에서. 완료 후 메인에서 알림.
    func delete(_ item: LibraryItem) {
        thumbnailCache[item.url] = nil
        let url = item.url
        ioQueue.async {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            }
        }
    }

    /// 원본 PNG를 백그라운드에서 읽어 메인에서 콜백. (미리보기/편집기 로드용)
    func loadImage(at url: URL, completion: @escaping (NSImage?) -> Void) {
        ioQueue.async {
            let image = NSImage(contentsOf: url)
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// 편집 결과 PNG를 라이브러리 파일에 덮어쓰기 저장(백그라운드) 후 메인에서 콜백.
    /// 전체 reload(.libraryDidChange)를 발생시키지 않는다 — 그러면 편집 중인 에디터가
    /// 새로고침되며 undo 스택이 날아가기 때문. 호출 측이 해당 썸네일만 갱신하도록 한다.
    func overwrite(pngData: Data, at url: URL, completion: (() -> Void)? = nil) {
        thumbnailCache[url] = nil
        ioQueue.async {
            try? pngData.write(to: url)
            DispatchQueue.main.async { completion?() }
        }
    }

    /// 효율적인 썸네일 (CGImageSource 다운샘플 + 캐시). 디스크 읽기는 백그라운드,
    /// 캐시 갱신/콜백은 메인에서.
    func thumbnail(for url: URL, maxPixel: CGFloat = 240, completion: @escaping (NSImage?) -> Void) {
        if let cached = thumbnailCache[url] { completion(cached); return }
        ioQueue.async { [weak self] in
            let image = Self.makeThumbnail(url: url, maxPixel: maxPixel)
            DispatchQueue.main.async {
                if let image { self?.thumbnailCache[url] = image }
                completion(image)
            }
        }
    }

    private static func makeThumbnail(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
    }
}
