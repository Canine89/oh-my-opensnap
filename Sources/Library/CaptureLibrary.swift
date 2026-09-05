import AppKit
import AVFoundation
import ImageIO

extension Notification.Name {
    static let libraryDidChange = Notification.Name("com.goldenrabbit.appresizer.libraryDidChange")
}

/// 캡처본을 라이브러리 폴더에 영구 보관하고 목록을 제공한다.
/// 기본 경로는 Application Support(신규 설치). 기존 바탕화면 폴더가 있으면 그걸 유지한다.
///
/// ⚠️ macOS 26(Tahoe)에서 바탕화면은 TCC 보호 폴더라, 첫 접근 시 "바탕화면 접근"
/// 동의창이 뜬다. 이 동의 검사는 호출 스레드를 블로킹하므로, **모든 디스크 I/O를
/// 메인 스레드가 아닌 `ioQueue`에서** 수행한다. (메인에서 하면 동의창이 떠 있는 동안
/// 런루프가 멈춰 무한 바람개비가 된다.)
// writeBuffer와 디스크 상태는 ioQueue에 한정하며 NSCache는 자체 동기화한다.
final class CaptureLibrary: @unchecked Sendable {
    static let shared = CaptureLibrary()

    /// 현재 저장 폴더. 사용자가 설정에서 고른 폴더(기본값: 바탕화면/oh-my-opensnap).
    var directory: URL { Settings.shared.libraryDirectory }
    /// thumbnailCache 는 메인 스레드에서만 읽고 쓴다.
    private let thumbnailCache = NSCache<NSURL, NSImage>()
    private let store = LibraryFileStore()
    // 실패한 쓰기는 메모리에 유지하고 다음 저장/종료 때 순서대로 재시도한다.
    private let writeBuffer = LibraryWriteBuffer()
    /// 바탕화면(TCC 보호) 디스크 I/O를 메인 런루프 밖에서 직렬 수행.
    private let ioQueue = DispatchQueue(label: "com.goldenrabbit.ohmyopensnap.library.io", qos: .userInitiated)

    private init() {
        thumbnailCache.countLimit = 300
        thumbnailCache.totalCostLimit = 64 * 1024 * 1024
        // 디렉터리 생성 + 레거시 이관은 바탕화면 접근이라 백그라운드에서.
        let dir = directory
        ioQueue.async { [weak self] in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #if !MAS
            self?.migrateLegacyIfNeeded()
            #endif
        }
    }

    /// 저장 폴더가 바뀌었을 때 호출 — 새 폴더를 만들고 목록 갱신 알림을 보낸다.
    func directoryDidChange() {
        let dir = directory
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                DispatchQueue.main.async { NotificationCenter.default.post(name: .libraryDidChange, object: nil) }
            } catch {
                DispatchQueue.main.async {
                    OperationErrorPresenter.show(error, action: loc("Could not use the selected folder", "선택한 저장 폴더를 사용할 수 없습니다"))
                }
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
    private func uniqueURL(for date: Date, directory: URL) -> URL {
        let base = fileName(for: date)
        var url = directory.appendingPathComponent(base + ".png")
        var suffix = 2
        while writeBuffer.contains(url) || FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: LibraryFileStore.annotationsURL(for: url).path) {
            url = directory.appendingPathComponent("\(base)-\(suffix).png")
            suffix += 1
        }
        return url
    }

    /// 캡처본 저장 후 변경 알림 발송. 디스크 쓰기는 백그라운드에서 수행하고
    /// 알림만 메인으로 되돌린다.
    func save(pngData: Data, date: Date, completion: @escaping (Result<URL, Error>) -> Void) {
        let directory = directory
        let access = Settings.shared.retainLibraryAccess(for: directory)
        ioQueue.async {
            defer { withExtendedLifetime(access) {} }
            let url = self.uniqueURL(for: date, directory: directory)
            let result = self.performWrite(at: url, recovery: { destination in
                try self.store.saveRecovered(image: pngData, annotations: nil, at: destination)
            }) {
                defer { withExtendedLifetime(access) {} }
                try self.store.saveNew(pngData, at: url)
            }
            DispatchQueue.main.async {
                completion(result.map { url })
                if case .success = result {
                    NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                }
            }
        }
    }

    /// 이 메서드와 writeBuffer는 ioQueue에서만 접근한다.
    private func performWrite(at url: URL, recovery: LibraryWriteBuffer.Recovery? = nil, operation: @escaping () throws -> Void) -> Result<Void, Error> {
        Result { try writeBuffer.enqueue(at: url, recovery: recovery, operation: operation) }
    }

    private func drainWrites(at url: URL) throws {
        try writeBuffer.retry(at: url)
    }

    func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                do {
                    try self.writeBuffer.flush()
                    DispatchQueue.main.async { continuation.resume() }
                } catch { DispatchQueue.main.async { continuation.resume(throwing: error) } }
            }
        }
    }

    func pendingWriteCount() async -> Int {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: self.writeBuffer.count) }
        }
    }

    func recoverPendingWrites(to directory: URL) async -> LibraryWriteBuffer.RecoveryReport {
        let access = SecurityScopedAccess(url: directory)
        return await withCheckedContinuation { continuation in
            ioQueue.async {
                defer { withExtendedLifetime(access) {} }
                continuation.resume(returning: self.writeBuffer.recover(to: directory))
            }
        }
    }

    func discardPendingWrites() async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                self.writeBuffer.discard()
                continuation.resume()
            }
        }
    }

    private func recovery(image: CGImage, annotations: Data?) -> LibraryWriteBuffer.Recovery {
        { destination in
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try self.store.saveRecovered(image: png, annotations: annotations, at: destination)
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
                try? fm.moveItem(at: old, to: uniqueURL(for: date, directory: directory))
            }
            // PNG 외 파일(gif/mp4, 사용자가 넣어둔 것)이 남아 있으면 폴더를 지우지 않는다.
            guard let contents = try? fm.contentsOfDirectory(atPath: legacy.path) else { continue }
            let remaining = contents.filter { $0 != ".DS_Store" }
            if remaining.isEmpty {
                try? fm.removeItem(at: legacy)
            }
        }
    }

    /// 최신순 목록을 백그라운드에서 읽어 메인에서 콜백한다.
    func loadItems(completion: @escaping (Result<[LibraryItem], Error>) -> Void) {
        let directory = directory
        let access = Settings.shared.retainLibraryAccess(for: directory)
        ioQueue.async {
            defer { withExtendedLifetime(access) {} }
            let result = Result { try LibraryCatalog.load(directory: directory, store: self.store) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 파일이 덮어써졌을 때 캐시된 썸네일을 버린다. (메인)
    func invalidateThumbnail(for url: URL) {
        thumbnailCache.removeObject(forKey: url as NSURL)
    }

    /// 휴지통으로 이동(바탕화면 접근)도 백그라운드에서. 완료 후 메인에서 알림.
    func delete(_ item: LibraryItem, completion: @escaping (Result<Void, Error>) -> Void) {
        let access = Settings.shared.retainLibraryAccess(for: item.url)
        ioQueue.async {
            defer { withExtendedLifetime(access) {} }
            // 휴지통 이동 실패를 종료 때 자동 재시도하지 않는다. 사용자가 다시 요청한다.
            let result = Result {
                try self.drainWrites(at: item.url)
                try self.store.trash(at: item.url)
            }
            DispatchQueue.main.async {
                completion(result)
                if case .success = result {
                    self.thumbnailCache.removeObject(forKey: item.url as NSURL)
                    NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                }
            }
        }
    }

    /// 이미지와 주석을 같은 큐 작업에서 읽어 서로 다른 편집 상태가 섞이지 않게 한다.
    func loadDocument(at url: URL, completion: @escaping (Result<(NSImage, Data?), Error>) -> Void) {
        let access = Settings.shared.retainLibraryAccess(for: url)
        ioQueue.async {
            defer { withExtendedLifetime(access) {} }
            let result = Result { () throws -> (NSImage, Data?) in
                try self.drainWrites(at: url)
                let document = try self.store.load(at: url)
                guard let image = NSImage(data: document.image) else { throw CocoaError(.fileReadCorruptFile) }
                return (image, document.annotations)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func saveEdit(image: CGImage, annotations: Data?, at url: URL,
                  completion: @escaping (Result<Void, Error>) -> Void) {
        let access = Settings.shared.retainLibraryAccess(for: url)
        ioQueue.async {
            defer { withExtendedLifetime(access) {} }
            let result = self.performWrite(at: url, recovery: self.recovery(image: image, annotations: annotations)) {
                defer { withExtendedLifetime(access) {} }
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try self.store.saveEdit(image: png, annotations: annotations, at: url)
            }
            DispatchQueue.main.async {
                if case .success = result { self.thumbnailCache.removeObject(forKey: url as NSURL) }
                completion(result)
            }
        }
    }

    func saveAnnotations(_ data: Data?, for imageURL: URL, image: CGImage) {
        let access = Settings.shared.retainLibraryAccess(for: imageURL)
        ioQueue.async {
            defer { withExtendedLifetime(access) {} }
            let result = self.performWrite(at: imageURL, recovery: self.recovery(image: image, annotations: data)) {
                defer { withExtendedLifetime(access) {} }
                try self.store.saveAnnotations(data, at: imageURL)
            }
            if case .failure(let error) = result {
                DispatchQueue.main.async {
                    SaveRecoveryController.shared.show(error)
                }
            }
        }
    }

    func export(data: Data, to url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let access = SecurityScopedAccess(url: url)
        ioQueue.async {
            defer { withExtendedLifetime(access) {} }
            let result = Result {
                try self.drainWrites(at: url)
                if url.pathExtension.lowercased() == "png",
                   FileManager.default.fileExists(atPath: LibraryFileStore.annotationsURL(for: url).path) {
                    try self.store.saveEdit(image: data, annotations: nil, at: url)
                } else { try CoordinatedFileExporter.write(data, to: url) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func exportFile(from source: URL, to url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let sourceAccess = SecurityScopedAccess(url: source)
        let destinationAccess = SecurityScopedAccess(url: url)
        ioQueue.async {
            defer { withExtendedLifetime((sourceAccess, destinationAccess)) {} }
            let result = Result { try CoordinatedFileExporter.copy(from: source, to: url) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func fileDidChange(_ url: URL? = nil) {
        if let url { thumbnailCache.removeObject(forKey: url as NSURL) }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        }
    }

    /// 효율적인 썸네일 (CGImageSource 다운샘플 + 캐시). 디스크 읽기는 백그라운드,
    /// 캐시 갱신/콜백은 메인에서.
    func thumbnail(for url: URL, maxPixel: CGFloat = 240, completion: @escaping (NSImage?) -> Void) {
        if let cached = thumbnailCache.object(forKey: url as NSURL) { completion(cached); return }
        if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            Task {
                let image = await Self.makeVideoThumbnail(url: url, maxPixel: maxPixel)
                await MainActor.run {
                    if let image { self.thumbnailCache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4)) }
                    completion(image)
                }
            }
            return
        }
        ioQueue.async { [weak self] in
            let image = Self.makeThumbnail(url: url, maxPixel: maxPixel)
            DispatchQueue.main.async {
                if let image { self?.thumbnailCache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4)) }
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

    private static func makeVideoThumbnail(url: URL, maxPixel: CGFloat) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let frame = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height))
    }
}
