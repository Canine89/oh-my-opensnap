import CoreGraphics
import Foundation

/// 접근성 트리가 웹·Electron 앱 전체를 하나의 `AXWebArea`로만 노출할 때,
/// 화면의 긴 가로/세로 경계를 읽어 실제 작업 표면을 찾는다.
///
/// 앱 이름이나 웹 사이트에 의존하지 않는다. 창 안의 상단 앱 바와 좌·우 탐색 패널을
/// 건너뛰고 가장 넓은 작업 패널을 고른다. 구조가 불분명하면 `nil`을 돌려 기존 AX
/// 콘텐츠 영역을 그대로 쓴다.
enum WindowSurfaceDetector {
    private struct RGB {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    /// - Parameters:
    ///   - image: 디스플레이 좌상단 원점의 정지 화면(BGRA 8-bit).
    ///   - windowRect: 해당 디스플레이 좌상단 기준 창 프레임(point).
    ///   - appContentRect: OS/앱 크롬을 제외한 1차 콘텐츠 프레임(point).
    ///   - scale: point → pixel 배율.
    /// - Returns: 앱 내부의 주 작업 패널(point), 불확실하면 `nil`.
    static func primarySurface(in image: CGImage,
                               windowRect: CGRect,
                               appContentRect: CGRect,
                               scale: CGFloat) -> CGRect? {
        guard image.bitsPerComponent == 8,
              image.bitsPerPixel >= 32,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return nil }

        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let requested = CGRect(x: windowRect.minX * scale,
                               y: windowRect.minY * scale,
                               width: windowRect.width * scale,
                               height: windowRect.height * scale).integral
        let source = requested.intersection(imageBounds)
        guard source.width >= 80, source.height >= 80 else { return nil }

        // 화면 전체를 매번 읽지 않는다. 약 420×280 샘플로 축소해 호버 중에도 가볍게 처리한다.
        let step = max(2, Int(ceil(max(source.width / 420, source.height / 280))))
        let columns = max(2, Int(source.width) / step)
        let rows = max(2, Int(source.height) / step)
        let bytesPerRow = image.bytesPerRow

        func sample(column: Int, row: Int) -> RGB {
            let x = min(Int(source.maxX) - 1, Int(source.minX) + column * step + step / 2)
            let y = min(Int(source.maxY) - 1, Int(source.minY) + row * step + step / 2)
            let offset = y * bytesPerRow + x * 4
            // SCScreenshotManager는 kCVPixelFormatType_32BGRA로 요청한다.
            return RGB(r: bytes[offset + 2], g: bytes[offset + 1], b: bytes[offset])
        }

        var pixels: [RGB] = []
        pixels.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                pixels.append(sample(column: column, row: row))
            }
        }
        func pixel(_ column: Int, _ row: Int) -> RGB { pixels[row * columns + column] }
        func difference(_ a: RGB, _ b: RGB) -> CGFloat {
            let value = abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
            return min(1, CGFloat(value) / 48)
        }

        let contentTop = max(0, appContentRect.minY - windowRect.minY)
        // OS 크롬과 앱 콘텐츠의 경계 바로 아래에는 1~2px 그림자·구분선이 남는다.
        // 이를 앱 내부 헤더의 끝으로 잘못 잡지 않도록 최소 한 줄의 앱 바 높이를 지난다.
        let minHeaderGap = max(32 * scale, CGFloat(step * 3))
        let startRow = min(rows - 1, max(1, Int((contentTop * scale + minHeaderGap) / CGFloat(step))))
        let maxHeaderRow = min(rows - 1, Int(CGFloat(rows) * 0.48))
        guard startRow < maxHeaderRow else { return nil }

        // 가로 경계: 텍스트처럼 국소적인 변화가 아니라 창 폭 전체에 이어지는 앱 바의
        // 배경 변화가 높은 점수를 얻는다.
        var bestRow: (index: Int, score: CGFloat)?
        for row in startRow...maxHeaderRow {
            var total: CGFloat = 0
            for column in 0..<columns {
                total += difference(pixel(column, row), pixel(column, row - 1))
            }
            let score = total / CGFloat(columns)
            // 아래쪽의 표/목록 구분선은 더 진할 수 있다. 주 작업 영역의 시작점은
            // 콘텐츠 시작 후 가장 먼저 창 폭을 가로지르는 안정적인 경계다.
            if score >= 0.19 {
                bestRow = (row, score)
                break
            }
        }
        guard let bestRow else { return nil }

        let top = CGFloat(bestRow.index * step) / scale
        let innerTop = max(appContentRect.minY, windowRect.minY + top)
        let remainingHeight = windowRect.maxY - innerTop
        guard remainingHeight >= appContentRect.height * 0.45 else { return nil }

        let firstContentRow = min(rows - 1, bestRow.index + 1)
        var boundaries = [0]
        if columns > 8 {
            for column in 1..<(columns - 1) {
                var total: CGFloat = 0
                var count = 0
                for row in firstContentRow..<rows {
                    total += difference(pixel(column, row), pixel(column - 1, row))
                    count += 1
                }
                let score = total / CGFloat(max(count, 1))
                // 카드의 그림자·텍스트 줄은 짧고, 사이드바 분리선은 세로로 길다.
                if score >= 0.17 { boundaries.append(column) }
            }
        }
        boundaries.append(columns)

        // 연속된 여러 샘플이 같은 분리선을 가리킬 수 있으므로 하나로 묶는다.
        var compact: [Int] = []
        for boundary in boundaries.sorted() {
            if let last = compact.last, boundary - last <= 2 { continue }
            compact.append(boundary)
        }
        if compact.last != columns { compact.append(columns) }

        var widest: (left: Int, right: Int)?
        for index in 0..<(compact.count - 1) {
            let left = compact[index]
            let right = compact[index + 1]
            let width = right - left
            guard CGFloat(width) / CGFloat(columns) >= 0.45 else { continue }
            if widest == nil || width > widest!.right - widest!.left {
                widest = (left, right)
            }
        }
        guard let widest else { return nil }

        let left = windowRect.minX + CGFloat(widest.left * step) / scale
        let right = min(windowRect.maxX, windowRect.minX + CGFloat(widest.right * step) / scale)
        let surface = CGRect(x: left, y: innerTop, width: right - left, height: remainingHeight).integral
        guard surface.width >= appContentRect.width * 0.45,
              surface.height >= appContentRect.height * 0.45,
              surface != appContentRect
        else { return nil }
        return surface
    }
}
