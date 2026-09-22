import CoreGraphics

/// 확대경(루페)과 그 아래 판독 알약(● HEX   X, Y)의 배치.
/// 그리기와 부분 무효화(damage)가 같은 계산을 써야 지난 프레임의 확대경·알약이 남지 않는다.
/// 좌표는 오버레이 뷰와 같은 좌상단 기준 point.
enum LoupeLayout {
    /// 커서와 확대경 사이 간격
    static let cursorGap: CGFloat = 24
    /// 화면 가장자리와의 최소 여백
    static let edgeMargin: CGFloat = 8
    /// 확대경과 판독 알약 사이 간격
    static let readoutGap: CGFloat = 6
    /// 테두리·밑선의 안티앨리어싱까지 지우는 여유
    static let damagePadding: CGFloat = 4

    // 판독 알약 내부 치수
    static let swatchSide: CGFloat = 10
    static let swatchSpacing: CGFloat = 6
    static let padX: CGFloat = 9
    static let padY: CGFloat = 5
    static let textSpacing: CGFloat = 8

    /// 측정한 글자 크기로 판독 알약 크기를 정한다.
    static func readoutSize(hexText: CGSize, coordinateText: CGSize) -> CGSize {
        CGSize(width: padX * 2 + swatchSide + swatchSpacing + hexText.width + textSpacing + coordinateText.width,
               height: padY * 2 + max(hexText.height, coordinateText.height, swatchSide))
    }

    /// 판독 알약은 확대경 바로 아래, 왼쪽 정렬.
    static func readoutFrame(below loupe: CGRect, size: CGSize) -> CGRect {
        CGRect(x: loupe.minX, y: loupe.maxY + readoutGap, width: size.width, height: size.height)
    }

    /// 확대경은 커서 오른쪽 아래에 두고, 확대경+판독 알약이 화면을 넘으면 반대편으로 뒤집는다.
    static func loupeFrame(at point: CGPoint, side: CGFloat, readoutHeight: CGFloat, in bounds: CGRect) -> CGRect {
        let below = readoutGap + readoutHeight
        var origin = CGPoint(x: point.x + cursorGap, y: point.y + cursorGap)
        if origin.x + side > bounds.maxX { origin.x = point.x - cursorGap - side }
        if origin.y + side + below > bounds.maxY { origin.y = point.y - cursorGap - side - below }
        origin.x = max(bounds.minX + edgeMargin, min(origin.x, bounds.maxX - side - edgeMargin))
        origin.y = max(bounds.minY + edgeMargin, min(origin.y, bounds.maxY - side - below - edgeMargin))
        return CGRect(origin: origin, size: CGSize(width: side, height: side))
    }

    /// 확대경과 판독 알약을 함께 덮는 무효화 영역.
    static func damageFrame(loupe: CGRect, readout: CGRect) -> CGRect {
        loupe.union(readout).insetBy(dx: -damagePadding, dy: -damagePadding)
    }
}
