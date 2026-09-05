import XCTest

final class LibraryWriteBufferTests: XCTestCase {
    func testRecoveryUsesLatestSnapshotAndOnlyClearsSuccessfulItems() throws {
        let buffer = LibraryWriteBuffer()
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.png")
        var restored: [Int] = []
        let fail: () throws -> Void = { throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try buffer.enqueue(at: first, recovery: { _ in restored.append(1) }, operation: fail))
        XCTAssertThrowsError(try buffer.enqueue(at: first, recovery: { _ in restored.append(2) }, operation: fail))
        XCTAssertThrowsError(try buffer.enqueue(at: second, recovery: { _ in throw CocoaError(.fileWriteOutOfSpace) }, operation: fail))
        let report = buffer.recover(to: URL(fileURLWithPath: "/tmp/recovered"))
        XCTAssertEqual(restored, [2])
        XCTAssertEqual(report.files.count, 1)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertFalse(buffer.contains(first))
        XCTAssertTrue(buffer.contains(second))
    }

    func testDiscardNeverExecutesFailedWritesOrRecovery() throws {
        let buffer = LibraryWriteBuffer()
        var attempts = 0
        let url = URL(fileURLWithPath: "/tmp/capture.png")
        XCTAssertThrowsError(try buffer.enqueue(at: url, recovery: { _ in XCTFail("버리기는 복구를 실행하지 않는다") }) {
            attempts += 1
            throw CocoaError(.fileWriteOutOfSpace)
        })
        buffer.discard()
        try buffer.flush()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(buffer.count, 0)
    }

    func testFailedWritesRetainOrderAndAreRetriedBeforeLaterEdits() throws {
        let buffer = LibraryWriteBuffer()
        let url = URL(fileURLWithPath: "/tmp/example.png")
        var writable = false
        var saved: [Int] = []
        XCTAssertThrowsError(try buffer.enqueue(at: url) {
            guard writable else { throw CocoaError(.fileWriteOutOfSpace) }
            saved.append(1)
        })
        XCTAssertTrue(buffer.contains(url))
        XCTAssertThrowsError(try buffer.enqueue(at: url) { saved.append(2) })
        XCTAssertTrue(saved.isEmpty)
        XCTAssertThrowsError(try buffer.flush())
        writable = true
        try buffer.flush()
        XCTAssertEqual(saved, [1, 2])
        XCTAssertFalse(buffer.contains(url))
        try buffer.flush()
        XCTAssertEqual(saved, [1, 2], "성공한 작업을 중복 실행하면 안 된다")
    }
}
