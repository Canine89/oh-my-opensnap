import CoreGraphics
import Foundation

/// 접근성 권한이 없거나 앱이 창 구조를 공개하지 않을 때, 앱별 추정 헤더 높이를
/// 정지 화면의 실제 경계선에 맞춘다.
///
/// 브라우저의 툴바/북마크바와 페이지 사이처럼 헤더와 본문 경계에는 창 폭 전체를
/// 가로지르는 색 변화가 있다. 추정값 근처(±tolerance)에서 가장 뚜렷한 가로 경계만
/// 찾으므로, 페이지 안쪽 구분선으로 튀어 나가지 않는다. 뚜렷한 경계가 없으면 `nil`.
enum HeaderEdgeRefiner {
    /// - Parameters:
    ///   - image: 디스플레이 좌상단 원점의 정지 화면(BGRA 8-bit).
    ///   - windowRect: 해당 디스플레이 좌상단 기준 창 프레임(point).
    ///   - candidateInset: 앱별 추정 헤더 높이(point).
    ///   - tolerance: 추정값에서 위아래로 살펴볼 범위(point).
    ///   - scale: point → pixel 배율.
    /// - Returns: 보정된 헤더 높이(point).
    static func refine(in image: CGImage,
                       windowRect: CGRect,
                       candidateInset: CGFloat,
                       tolerance: CGFloat,
                       scale: CGFloat) -> CGFloat? {
        guard image.bitsPerComponent == 8,
              image.bitsPerPixel >= 32,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return nil }

        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let window = CGRect(x: windowRect.minX * scale,
                            y: windowRect.minY * scale,
                            width: windowRect.width * scale,
                            height: windowRect.height * scale).integral.intersection(imageBounds)
        guard window.width >= 80 * scale, window.height >= 120 * scale else { return nil }

        // 둥근 모서리·창 테두리를 피해 안쪽만 본다.
        let marginX = Int(window.width * 0.04)
        let firstX = Int(window.minX) + marginX
        let lastX = Int(window.maxX) - marginX - 1
        guard lastX - firstX >= 40 else { return nil }
        let stepX = max(1, (lastX - firstX) / 240)
        var columns: [Int] = []
        var x = firstX
        while x <= lastX {
            columns.append(x)
            x += stepX
        }

        let windowTop = Int(window.minY)
        let lowest = Int(window.maxY) - Int(40 * scale)
        let firstY = max(windowTop + Int(16 * scale), windowTop + Int((candidateInset - tolerance) * scale))
        let lastY = min(lowest, windowTop + Int((candidateInset + tolerance) * scale))
        guard firstY + 1 <= lastY else { return nil }

        let bytesPerRow = image.bytesPerRow
        func differs(_ x: Int, _ y: Int) -> Bool {
            let upper = (y - 1) * bytesPerRow + x * 4
            let lower = y * bytesPerRow + x * 4
            let delta = abs(Int(bytes[lower]) - Int(bytes[upper]))
                + abs(Int(bytes[lower + 1]) - Int(bytes[upper + 1]))
                + abs(Int(bytes[lower + 2]) - Int(bytes[upper + 2]))
            return delta >= 30
        }

        // 각 픽셀 행이 바로 윗줄과 얼마나 넓게 다른지(창 폭 대비 비율)를 잰다.
        var scores: [(y: Int, score: CGFloat)] = []
        scores.reserveCapacity(lastY - firstY)
        for y in (firstY + 1)...lastY {
            var hits = 0
            for column in columns where differs(column, y) { hits += 1 }
            scores.append((y, CGFloat(hits) / CGFloat(columns.count)))
        }
        guard let best = scores.max(by: { $0.score < $1.score }), best.score >= 0.55 else { return nil }

        // 구분선(1~2px)은 위·아래 두 줄이 모두 경계로 잡힌다. 선은 헤더에 남기고
        // 본문은 그 아래에서 시작하도록, 최고점 바로 아래의 강한 줄까지 내려간다.
        var edgeY = best.y
        for entry in scores where entry.y > best.y && entry.y <= best.y + Int(3 * scale) && entry.score >= best.score * 0.6 {
            edgeY = max(edgeY, entry.y)
        }
        return CGFloat(edgeY - windowTop) / scale
    }
}
