import XCTest
import CoreGraphics

final class DisplaySnapshotRequestTests: XCTestCase {
    func testCaptureStartsImmediatelyAndRetainsImageUntilAwaited() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = try XCTUnwrap(context.makeImage())
        var requested = false
        let request = DisplaySnapshotRequest(scale: 2) { completion in
            requested = true
            completion(image, nil)
        }
        XCTAssertTrue(requested, "대기나 Task 실행 전에 캡처 요청이 시작되어야 한다")
        let snapshot = try await request.value()
        XCTAssertTrue(snapshot.image === image)
        XCTAssertEqual(snapshot.scale, 2)
        let crop = try XCTUnwrap(snapshot.crop(viewRect: CGRect(x: 1, y: 1, width: 4, height: 5)))
        XCTAssertEqual(crop.width, 8)
        XCTAssertEqual(crop.height, 10)
    }

    func testAsynchronousCompletionDeliversOriginalSnapshot() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        var complete: (@Sendable (CGImage?, Error?) -> Void)?
        let request = DisplaySnapshotRequest(scale: 1) { complete = $0 }
        let callback = try XCTUnwrap(complete)
        Task { callback(image, nil) }
        let snapshot = try await request.value()
        XCTAssertTrue(snapshot.image === image)
    }

    func testCaptureFailureIsPropagated() async {
        let expected = NSError(domain: "snapshot-test", code: 123)
        let request = DisplaySnapshotRequest(scale: 2) { $0(nil, expected) }
        do {
            _ = try await request.value()
            XCTFail("캡처 실패를 성공으로 처리하면 안 된다")
        } catch {
            XCTAssertEqual(error as NSError, expected)
        }
    }

    func testMissingImageFailsInsteadOfWaitingForever() async {
        let request = DisplaySnapshotRequest(scale: 2) { $0(nil, nil) }
        do {
            _ = try await request.value()
            XCTFail("이미지가 없는 응답은 실패해야 한다")
        } catch { }
    }
}
