import XCTest
import CoreGraphics

final class WindowCropTests: XCTestCase {
    /// 창 이미지(창 전체, 화면 밖 포함)의 픽셀 → 창 로컬 point. 화면에 보이던 부분과 같은지 확인한다.
    private func assertCrop(selection: CGRect, windowFrame: CGRect, scale: CGFloat,
                            expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let imageSize = CGSize(width: windowFrame.width * scale, height: windowFrame.height * scale)
        let rect = WindowCrop.pixelRect(selection: selection, windowFrame: windowFrame,
                                        scale: scale, imageSize: imageSize)
        XCTAssertEqual(rect, expected, file: file, line: line)
    }

    func testWindowFullyOnScreenCropsFromWindowOrigin() {
        assertCrop(selection: CGRect(x: 110, y: 90, width: 400, height: 250),
                   windowFrame: CGRect(x: 100, y: 50, width: 500, height: 300),
                   scale: 2,
                   expected: CGRect(x: 20, y: 80, width: 800, height: 500))
    }

    func testWindowPartiallyOffLeftEdgeSkipsHiddenPart() {
        // 창이 디스플레이 왼쪽으로 100pt 나가 있다. 보이는 부분은 창의 x=100pt부터다.
        let windowFrame = CGRect(x: -100, y: 40, width: 400, height: 300)
        let visibleFull = windowFrame.intersection(CGRect(x: 0, y: 0, width: 1440, height: 900))
        assertCrop(selection: visibleFull, windowFrame: windowFrame, scale: 2,
                   expected: CGRect(x: 200, y: 0, width: 600, height: 600))
    }

    func testWindowPartiallyAboveTopEdgeContentZone() {
        // 창 위쪽 60pt가 디스플레이 밖(다른 디스플레이)이고, 본문(헤더 32pt 아래)만 선택했다.
        let windowFrame = CGRect(x: 200, y: -60, width: 500, height: 400)
        let content = CGRect(x: 200, y: -28, width: 500, height: 368)
        let selection = content.intersection(CGRect(x: 0, y: 0, width: 1440, height: 900))
        assertCrop(selection: selection, windowFrame: windowFrame, scale: 1,
                   expected: CGRect(x: 0, y: 60, width: 500, height: 340))
    }

    func testWindowSpanningRightEdgeKeepsLeftPart() {
        let windowFrame = CGRect(x: 1200, y: 100, width: 500, height: 300)
        let selection = windowFrame.intersection(CGRect(x: 0, y: 0, width: 1440, height: 900))
        assertCrop(selection: selection, windowFrame: windowFrame, scale: 2,
                   expected: CGRect(x: 0, y: 0, width: 480, height: 600))
    }

    func testClampsToImageAndRejectsDisjointSelection() {
        let windowFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        // 창 이미지가 반올림으로 1px 작게 와도 이미지 안으로 가둔다.
        let clamped = WindowCrop.pixelRect(selection: windowFrame, windowFrame: windowFrame, scale: 2,
                                           imageSize: CGSize(width: 199, height: 199))
        XCTAssertEqual(clamped, CGRect(x: 0, y: 0, width: 199, height: 199))
        XCTAssertNil(WindowCrop.pixelRect(selection: CGRect(x: 300, y: 300, width: 10, height: 10),
                                          windowFrame: windowFrame, scale: 2,
                                          imageSize: CGSize(width: 200, height: 200)))
    }
}
