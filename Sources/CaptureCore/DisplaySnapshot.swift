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

    /// 캡처 API가 반환한 지연 렌더링 이미지를 한 번만 BGRA 픽셀로 펼친다.
    /// 확대경 crop/헤더 분석/배경 레이어가 같은 비트맵을 재사용하게 한다.
    /// 전체 화면 변환이므로 호출자는 메인 스레드 밖에서 실행해야 한다.
    static func rasterizedImage(_ image: CGImage) -> CGImage? {
        let colorSpace = image.colorSpace?.model == .rgb
            ? image.colorSpace! : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// 펼치기에 실패해도 캡처된 원본은 유효하므로 버리지 않고 그대로 쓴다.
    /// (펼치기는 반복 디코딩을 줄이는 최적화일 뿐, 정지 화면·확정 캡처의 전제 조건이 아니다.)
    static func preparedImage(_ image: CGImage,
                              rasterize: (CGImage) -> CGImage? = rasterizedImage) -> CGImage {
        rasterize(image) ?? image
    }

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
