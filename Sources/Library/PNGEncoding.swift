import AppKit

/// 캡처·편집 결과의 PNG 인코딩을 한 곳에 모은다.
/// Retina 배율을 DPI(pHYs)로 기록해야 Keynote·미리보기 등에 붙여넣을 때 논리 크기(point)로 들어간다.
/// (배율 2 → 144dpi. `NSBitmapImageRep(cgImage:)`만 쓰면 72dpi로 저장돼 2배 크기로 붙는다.)
enum PNGEncoding {
    static func data(from image: CGImage, scale: CGFloat) -> Data? {
        let scale = normalizedScale(scale)
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }

    /// 픽셀 수와 논리 크기(point)의 비율. 파일에서 읽은 NSImage 크기는 DPI를 반영하므로 이것이 원본 배율이다.
    static func scale(pixelWidth: Int, logicalWidth: CGFloat) -> CGFloat {
        guard logicalWidth > 0 else { return 1 }
        return normalizedScale(CGFloat(pixelWidth) / logicalWidth)
    }

    /// PNG의 pHYs는 미터당 정수 픽셀이라 144dpi가 143.99dpi로 읽힌다. 소수 둘째 자리로 맞춘다.
    private static func normalizedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        return (scale * 100).rounded() / 100
    }
}
