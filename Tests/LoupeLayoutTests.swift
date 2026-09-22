import XCTest
import CoreGraphics

final class LoupeLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let side: CGFloat = 184

    private var samplePoints: [CGPoint] {
        var points: [CGPoint] = []
        for x in stride(from: 0, through: bounds.width, by: 37) {
            for y in stride(from: 0, through: bounds.height, by: 29) {
                points.append(CGPoint(x: x, y: y))
            }
        }
        return points + [CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: 0),
                         CGPoint(x: 0, y: bounds.maxY)]
    }

    func testReadoutSizeFollowsMeasuredText() {
        let size = LoupeLayout.readoutSize(hexText: CGSize(width: 50, height: 13),
                                           coordinateText: CGSize(width: 70, height: 13))
        let expectedWidth: CGFloat = 162   // 9*2 + 10 + 6 + 50 + 8 + 70
        XCTAssertEqual(size.width, expectedWidth)
        XCTAssertEqual(size.height, 23)
        // 글자가 스와치보다 낮아도 스와치가 들어갈 높이는 확보한다.
        XCTAssertEqual(LoupeLayout.readoutSize(hexText: CGSize(width: 1, height: 4),
                                               coordinateText: CGSize(width: 1, height: 4)).height, 20)
    }

    func testDamageCoversLoupeAndReadoutEverywhere() {
        // 좌표 자릿수가 많아 확대경보다 넓어진 알약(과거 하드코딩 320pt를 넘는 폭 포함)도 덮어야 한다.
        for readoutWidth: CGFloat in [120, 240, 360] {
            let readoutSize = CGSize(width: readoutWidth, height: 23)
            for point in samplePoints {
                let loupe = LoupeLayout.loupeFrame(at: point, side: side, readoutHeight: readoutSize.height, in: bounds)
                let readout = LoupeLayout.readoutFrame(below: loupe, size: readoutSize)
                let damage = LoupeLayout.damageFrame(loupe: loupe, readout: readout)
                XCTAssertTrue(damage.contains(loupe.insetBy(dx: -1, dy: -1)), "테두리까지 덮어야 한다: \(point)")
                XCTAssertTrue(damage.contains(readout.insetBy(dx: -1, dy: -1)), "판독 알약까지 덮어야 한다: \(point)")
            }
        }
    }

    func testWidestReadoutDamageCoversNarrowerReadouts() {
        // 무효화는 가장 넓은 HEX로 계산하고, 실제 그리기는 현재 색으로 한다 → 좁은 알약은 늘 그 안에 든다.
        for point in samplePoints {
            let loupe = LoupeLayout.loupeFrame(at: point, side: side, readoutHeight: 23, in: bounds)
            let widest = LoupeLayout.damageFrame(
                loupe: loupe, readout: LoupeLayout.readoutFrame(below: loupe, size: CGSize(width: 220, height: 23)))
            let actual = LoupeLayout.readoutFrame(below: loupe, size: CGSize(width: 190, height: 23))
            XCTAssertTrue(widest.contains(actual))
        }
    }

    func testLoupeAndReadoutStayOnScreenAndOffCursor() {
        let readoutHeight: CGFloat = 23
        for point in samplePoints {
            let loupe = LoupeLayout.loupeFrame(at: point, side: side, readoutHeight: readoutHeight, in: bounds)
            let readout = LoupeLayout.readoutFrame(below: loupe, size: CGSize(width: 150, height: readoutHeight))
            XCTAssertGreaterThanOrEqual(loupe.minX, bounds.minX + LoupeLayout.edgeMargin)
            XCTAssertGreaterThanOrEqual(loupe.minY, bounds.minY + LoupeLayout.edgeMargin)
            XCTAssertLessThanOrEqual(loupe.maxX, bounds.maxX - LoupeLayout.edgeMargin)
            XCTAssertLessThanOrEqual(readout.maxY, bounds.maxY - LoupeLayout.edgeMargin, "알약이 화면 아래로 잘리면 안 된다: \(point)")
        }
        // 오른쪽 아래 구석에서는 커서 왼쪽 위로 뒤집혀 조준점을 가리지 않는다.
        let corner = CGPoint(x: bounds.maxX - 30, y: bounds.maxY - 30)
        let loupe = LoupeLayout.loupeFrame(at: corner, side: side, readoutHeight: readoutHeight, in: bounds)
        let readout = LoupeLayout.readoutFrame(below: loupe, size: CGSize(width: 150, height: readoutHeight))
        XCTAssertFalse(loupe.union(readout).contains(corner))
    }
}
