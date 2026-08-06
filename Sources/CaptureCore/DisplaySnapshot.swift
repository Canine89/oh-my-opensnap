import CoreGraphics

/// 캡처 모드에 들어간 순간의 디스플레이 정지 화면.
///
/// 두 가지로 쓴다:
/// - 오버레이 배경으로 깔아 뒤 화면이 재생 중이어도 멈춘 화면에서 영역을 고르게 한다.
/// - 확정된 선택을 여기서 잘라낸다. 라이브로 다시 캡처하지 않으므로 화면에서 조준한 프레임이 그대로 저장된다.
struct DisplaySnapshot {
    let image: CGImage
    /// point → pixel 스케일 (Retina에서 2.0)
    let scale: CGFloat

    /// 오버레이 뷰 좌표(디스플레이 좌상단 기준 point)를 픽셀로 바꿔 잘라낸다.
    func crop(viewRect: CGRect) -> CGImage? {
        guard viewRect.width > 2, viewRect.height > 2 else { return nil }
        let pxRect = CGRect(x: viewRect.minX * scale,
                            y: viewRect.minY * scale,
                            width: viewRect.width * scale,
                            height: viewRect.height * scale).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = pxRect.intersection(bounds)
        guard !clamped.isEmpty else { return nil }
        return image.cropping(to: clamped)
    }
}
