import XCTest
import CoreVideo

final class DisplayFrameCacheTests: XCTestCase {
    func testOldStreamCallbacksCannotRestoreStoppedOrReplacedFrames() throws {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &value), kCVReturnSuccess)
        let pixel = try XCTUnwrap(value)
        let oldStream = NSObject()
        let newStream = NSObject()
        let cache = DisplayFrameCache()
        cache.activate(oldStream)
        cache.store(pixel, from: oldStream)
        XCTAssertNotNil(cache.latest())
        cache.clear()
        cache.store(pixel, from: oldStream)
        XCTAssertNil(cache.latest())
        cache.activate(newStream)
        cache.store(pixel, from: oldStream)
        XCTAssertNil(cache.latest())
        cache.store(pixel, from: newStream)
        XCTAssertNotNil(cache.latest())
    }
}
