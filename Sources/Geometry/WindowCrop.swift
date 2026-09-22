import CoreGraphics

/// 창 단독 캡처(`SCContentFilter(desktopIndependentWindow:)`) 결과에서 선택 영역을 잘라내는 좌표 계산.
/// 창 이미지는 디스플레이 밖으로 나간 부분까지 창 전체를 담으므로, 오프셋은 디스플레이에 잘리기 전의
/// 창 프레임을 기준으로 계산해야 한다. 잘린 프레임을 원점으로 쓰면 창이 화면 왼쪽/위로 걸친 만큼
/// 엉뚱한 부분이 저장된다.
enum WindowCrop {
    /// - Parameters:
    ///   - selection: 오버레이 로컬 좌표(point)의 선택. 디스플레이 안으로 잘린 값.
    ///   - windowFrame: 같은 좌표계의 창 전체 프레임. 디스플레이에 잘리지 않은 값.
    ///   - scale: 창 이미지의 point → pixel 배율
    ///   - imageSize: 창 이미지 크기(pixel)
    /// - Returns: 창 이미지 안의 픽셀 사각형. 겹치는 부분이 없으면 nil.
    static func pixelRect(selection: CGRect, windowFrame: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect? {
        let visible = selection.intersection(windowFrame)
        guard !visible.isNull, !visible.isEmpty, scale > 0 else { return nil }
        let pxRect = CGRect(x: (visible.minX - windowFrame.minX) * scale,
                            y: (visible.minY - windowFrame.minY) * scale,
                            width: visible.width * scale,
                            height: visible.height * scale).integral
        let clamped = pxRect.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clamped.isNull, !clamped.isEmpty else { return nil }
        return clamped
    }
}
