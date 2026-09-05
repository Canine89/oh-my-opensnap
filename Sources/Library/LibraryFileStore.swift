import Foundation
import Darwin

/// 직렬 I/O 큐에서만 사용한다. 이미지·주석의 쌍을 복구 기록과 함께 저장한다.
/// 기록 삭제가 커밋 지점이며, 중간에 종료되면 다음 읽기 전에 이전 상태로 복구한다.
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

    func load(at image: URL) throws -> (image: Data, annotations: Data?) {
        try recover(at: image)
        return (try Data(contentsOf: image), try readAnnotations(at: image))
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

    func saveEdit(image data: Data, annotations: Data?, at image: URL) throws {
        let previous = try load(at: image)
        let journal = Self.recoveryURL(for: image)
        try fm.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try write(encoder.encode(Recovery(image: previous.image, annotations: previous.annotations)), journal)
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
    }

    func saveAnnotations(_ data: Data?, at image: URL) throws {
        try recover(at: image)
        guard fm.fileExists(atPath: image.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try writeAnnotations(data, at: image)
    }

    func trash(at image: URL) throws {
        try recover(at: image)
        try moveToTrash(image)
        // 주석은 보존한다. Finder에서 원본 위치로 복원하면 편집도 복원된다.
        // 신규 캡처 이름은 이 주석 파일도 확인해 재사용하지 않는다.
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
