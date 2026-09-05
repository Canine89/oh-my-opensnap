import Foundation

/// 호출자가 하나의 직렬 큐로 보호한다. 실패한 작업과 이후 편집의 순서를 유지한다.
final class LibraryWriteBuffer {
    private var pending: [URL: [() throws -> Void]] = [:]
    func contains(_ url: URL) -> Bool { pending[url] != nil }

    func enqueue(at url: URL, operation: @escaping () throws -> Void) throws {
        pending[url, default: []].append(operation)
        try retry(at: url)
    }

    func retry(at url: URL) throws {
        while let operation = pending[url]?.first {
            try operation()
            pending[url]?.removeFirst()
        }
        pending[url] = nil
    }

    func flush() throws {
        for url in Array(pending.keys) { try retry(at: url) }
    }
}
