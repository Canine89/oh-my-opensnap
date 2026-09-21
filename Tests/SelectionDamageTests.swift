import XCTest
import CoreGraphics

final class SelectionDamageTests: XCTestCase {
    func testDamageCoversExactlyChangedPixels() {
        let old = CGRect(x: 4, y: 4, width: 12, height: 10)
        for new in [old, old.offsetBy(dx: 2, dy: 3), old.insetBy(dx: 2, dy: 2),
                    old.insetBy(dx: -2, dy: -2), old.offsetBy(dx: 15, dy: 0), .zero] {
            let damage = SelectionDamage.rectangles(from: old, to: new)
            for y in 0..<32 {
                for x in 0..<32 {
                    let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    XCTAssertEqual(damage.contains { $0.contains(point) },
                                   old.contains(point) != new.contains(point),
                                   "디밍이 바뀐 픽셀만 무효화해야 한다: \(point), \(new)")
                }
            }
        }
    }

    func testSmallResizeDoesNotRedrawLargeSelectionInterior() {
        let old = CGRect(x: 100, y: 100, width: 2000, height: 1000)
        let new = CGRect(x: 100, y: 100, width: 2002, height: 1000)
        let damage = SelectionDamage.rectangles(from: old, to: new)
        XCTAssertEqual(damage.reduce(CGFloat.zero) { $0 + $1.width * $1.height }, 2000)
        XCTAssertFalse(damage.contains { $0.contains(CGPoint(x: 500, y: 500)) })
    }
}
