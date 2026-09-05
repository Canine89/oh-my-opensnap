import Foundation

/// 호출자가 직렬 큐로 보호한다. 실패한 작업과 최신 복구 스냅샷을 함께 보관한다.
final class LibraryWriteBuffer {
    typealias Recovery = (URL) throws -> Void
    private struct Entry {
        let operation: () throws -> Void
        let recovery: Recovery?
    }
    struct RecoveryReport {
        var files: [URL: URL] = [:]
        var failures: [URL: Error] = [:]
    }
    private var pending: [URL: [Entry]] = [:]
    var count: Int { pending.count }
    func contains(_ url: URL) -> Bool { pending[url] != nil }

    func enqueue(at url: URL, recovery: Recovery? = nil, operation: @escaping () throws -> Void) throws {
        pending[url, default: []].append(Entry(operation: operation, recovery: recovery))
        try retry(at: url)
    }

    func retry(at url: URL) throws {
        while let entry = pending[url]?.first {
            try entry.operation()
            pending[url]?.removeFirst()
        }
        pending[url] = nil
    }

    func flush() throws {
        for url in Array(pending.keys) { try retry(at: url) }
    }

    /// 복구 성공한 항목만 제거한다. 실패한 나머지는 메모리에 그대로 보존한다.
    func recover(to directory: URL) -> RecoveryReport {
        var report = RecoveryReport()
        for url in pending.keys.sorted(by: { $0.path < $1.path }) {
            do {
                guard let recover = pending[url]?.last?.recovery else { throw CocoaError(.fileReadUnknown) }
                let name = url.deletingPathExtension().lastPathComponent + "-recovered-" + UUID().uuidString
                let destination = directory.appendingPathComponent(name).appendingPathExtension(url.pathExtension)
                try recover(destination)
                report.files[url] = destination
                pending[url] = nil
            } catch { report.failures[url] = error }
        }
        return report
    }

    /// 사용자에게 명시적으로 확인받은 뒤에만 호출한다. 디스크의 복구 기록은 지우지 않는다.
    func discard() { pending.removeAll() }
}
