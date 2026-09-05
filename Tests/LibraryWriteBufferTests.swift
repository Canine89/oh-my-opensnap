import XCTest

final class LibraryWriteBufferTests: XCTestCase {
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
