import Foundation
import Darwin

/// 직렬 I/O 큐에서만 사용한다. 이미지·주석의 쌍을 복구 기록과 함께 저장한다.
/// 기록 삭제가 커밋 지점이며, 중간에 종료되면 다음 읽기 전에 이전 상태로 복구한다.
/// 얹은 이미지 원본은 `.annotations/<파일명>.assets/<uuid>.png`에 둔다. 새 자산은 JSON보다 먼저 쓰고,
/// 참조가 끊긴 자산은 커밋이 끝난 뒤에만 지운다 — 복구 기록이 되살리는 이전 JSON의 자산이 남아 있게.
final class LibraryFileStore {
    typealias Write = (Data, URL) throws -> Void
    private let fm: FileManager
    private let write: Write
    private let moveToTrash: (URL) throws -> Void

    init(fileManager: FileManager = .default,
         write: @escaping Write = { try $0.write(to: $1, options: .atomic) },
         moveToTrash: @escaping (URL) throws -> Void = {
             try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
         }) {
        fm = fileManager
        self.write = write
        self.moveToTrash = moveToTrash
    }

    static func annotationsURL(for image: URL) -> URL {
        image.deletingLastPathComponent().appendingPathComponent(".annotations", isDirectory: true)
            .appendingPathComponent(image.lastPathComponent + ".json")
    }

    static func recoveryURL(for image: URL) -> URL {
        annotationsURL(for: image).appendingPathExtension("recovery")
    }

    static func assetsURL(for image: URL) -> URL {
        image.deletingLastPathComponent().appendingPathComponent(".annotations", isDirectory: true)
            .appendingPathComponent(image.lastPathComponent + ".assets", isDirectory: true)
    }

    /// 자산 ID는 UUID만 허용한다 — JSON에 경로 조각이 들어와도 폴더 밖을 가리키지 못하게.
    static func assetURL(id: String, for image: URL) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return assetsURL(for: image).appendingPathComponent(id + ".png")
    }

    private struct Recovery: Codable {
        let image: Data
        let annotations: Data?
    }

    func recover(at image: URL) throws {
        let journal = Self.recoveryURL(for: image)
        guard fm.fileExists(atPath: journal.path) else { return }
        let previous = try PropertyListDecoder().decode(Recovery.self, from: Data(contentsOf: journal))
        try write(previous.image, image)
        try writeAnnotations(previous.annotations, at: image)
        try fm.removeItem(at: journal)
    }

    /// 자산은 읽을 수 있는 것만 담는다. 하나가 깨져도 문서는 열린다(편집기가 그 오브제만 건너뛴다).
    func load(at image: URL) throws -> (image: Data, annotations: Data?, assets: [String: Data]) {
        try recover(at: image)
        return (try Data(contentsOf: image), try readAnnotations(at: image), readAssets(at: image))
    }

    func saveNew(_ data: Data, at image: URL) throws {
        try fm.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 신규 저장은 기존 파일을 덮어쓰지 않는다.
        let staging = image.deletingLastPathComponent().appendingPathComponent(".capture-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try write(data, staging)
        guard renamex_np(staging.path, image.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func saveRecovered(image: Data, annotations: Data?, assets: [String: Data]? = nil, at destination: URL) throws {
        try saveNew(image, at: destination)
        do { try saveAnnotations(annotations, assets: assets, at: destination) }
        catch {
            // 이번 복구가 생성한 파일만 정리한다. 메모리의 원본 복구 스냅샷은 유지된다.
            try? fm.removeItem(at: destination)
            try? fm.removeItem(at: Self.annotationsURL(for: destination))
            try? fm.removeItem(at: Self.assetsURL(for: destination))
            throw error
        }
    }

    /// `assets`는 `annotations`가 참조하는 자산 전부. nil이면 자산 폴더를 건드리지 않는다(주석이 없으면 비운다).
    func saveEdit(image data: Data, annotations: Data?, assets: [String: Data]? = nil, at image: URL) throws {
        try recover(at: image)
        let previousImage = try Data(contentsOf: image)
        let previousAnnotations = try readAnnotations(at: image)
        try writeAssets(assets, at: image)
        let journal = Self.recoveryURL(for: image)
        try fm.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try write(encoder.encode(Recovery(image: previousImage, annotations: previousAnnotations)), journal)
        do {
            try write(data, image)
            try writeAnnotations(annotations, at: image)
            try fm.removeItem(at: journal)
        } catch {
            // 복구 실패 시에도 기록은 보존되어 다음 읽기/저장 때 재시도된다.
            let saveError = error
            try recover(at: image)
            throw saveError
        }
        pruneAssets(keeping: annotations == nil ? [] : assets.map { Set($0.keys) }, at: image)
    }

    func saveAnnotations(_ data: Data?, assets: [String: Data]? = nil, at image: URL) throws {
        try recover(at: image)
        guard fm.fileExists(atPath: image.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try writeAssets(assets, at: image)
        try writeAnnotations(data, at: image)
        pruneAssets(keeping: data == nil ? [] : assets.map { Set($0.keys) }, at: image)
    }

    func trash(at image: URL) throws {
        try recover(at: image)
        try moveToTrash(image)
        // 주석 JSON과 얹은 이미지 원본은 보존한다. Finder에서 원본 위치로 복원하면 편집도 그대로 복원된다.
        // 신규 캡처 이름은 이 주석 파일도 확인해 재사용하지 않는다.
    }

    private func readAssets(at image: URL) -> [String: Data] {
        let folder = Self.assetsURL(for: image)
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var assets: [String: Data] = [:]
        for name in names where name.hasSuffix(".png") {
            let id = String(name.dropLast(4))
            guard let url = Self.assetURL(id: id, for: image) else { continue }
            do { assets[id] = try Data(contentsOf: url) }
            catch { NSLog("Reading inserted image %@ failed: %@", name, error.localizedDescription) }
        }
        return assets
    }

    /// 자산은 ID(UUID)별로 내용이 바뀌지 않으므로 이미 있는 파일은 다시 쓰지 않는다.
    private func writeAssets(_ assets: [String: Data]?, at image: URL) throws {
        guard let assets, !assets.isEmpty else { return }
        try fm.createDirectory(at: Self.assetsURL(for: image), withIntermediateDirectories: true)
        for (id, data) in assets {
            guard let url = Self.assetURL(id: id, for: image), !fm.fileExists(atPath: url.path) else { continue }
            try write(data, url)
        }
    }

    /// 참조가 끊긴 자산 정리. 정리 실패는 저장 실패가 아니다(다음 저장 때 다시 정리된다).
    private func pruneAssets(keeping ids: Set<String>?, at image: URL) {
        guard let ids else { return }
        let folder = Self.assetsURL(for: image)
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where !(name.hasSuffix(".png") && ids.contains(String(name.dropLast(4)))) {
            do { try fm.removeItem(at: folder.appendingPathComponent(name)) }
            catch { NSLog("Pruning inserted image %@ failed: %@", name, error.localizedDescription) }
        }
        if ids.isEmpty, (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fm.removeItem(at: folder)
        }
    }

    private func readAnnotations(at image: URL) throws -> Data? {
        let url = Self.annotationsURL(for: image)
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func writeAnnotations(_ data: Data?, at image: URL) throws {
        let url = Self.annotationsURL(for: image)
        if let data {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(data, url)
        } else if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }
}
