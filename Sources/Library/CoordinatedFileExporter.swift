import Foundation

/// 저장 패널이 허용한 파일과 운영체제가 제공한 교체 디렉터리만 사용한다.
/// 큰 영상도 통째로 메모리에 올리지 않고 복사한다. 호출은 I/O 큐에서 수행한다.
enum CoordinatedFileExporter {
    static func write(_ data: Data, to destination: URL) throws {
        try replace(destination) { staging in try data.write(to: staging, options: .atomic) }
    }

    static func copy(from source: URL, to destination: URL) throws {
        if source.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() { return }
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinatedSource in
            do {
                try replace(destination) { try FileManager.default.copyItem(at: coordinatedSource, to: $0) }
            } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
    }

    static func replace(_ destination: URL, write: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                let fm = FileManager.default
                let replacement = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                             appropriateFor: coordinated, create: true)
                defer { try? fm.removeItem(at: replacement) }
                let staging = replacement.appendingPathComponent(coordinated.lastPathComponent)
                try write(staging)
                if fm.fileExists(atPath: coordinated.path) {
                    _ = try fm.replaceItemAt(coordinated, withItemAt: staging)
                } else {
                    try fm.moveItem(at: staging, to: coordinated)
                }
            } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
    }
}
