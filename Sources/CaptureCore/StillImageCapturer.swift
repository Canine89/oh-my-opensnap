import ScreenCaptureKit
import CoreGraphics

/// 최종 캡처용 정지 이미지. 구 `CGWindowListCreateImage`를 대체하는
/// `SCScreenshotManager`로 디스플레이를 풀 픽셀 해상도로 1장 캡처한다.
enum StillImageCapturer {
    enum CaptureError: Error { case noImage }

    /// 디스플레이 전체를 캡처한다. 선택 영역 crop은 호출 측에서 픽셀 단위로 수행.
    /// (sourceRect 좌표 미묘함을 피하고 정확도를 우선 — 전체 캡처 후 crop)
    static func capture(display: SCDisplay, scale: CGFloat, excluding: [SCWindow] = []) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: excluding)

        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 단일 윈도우를 풀 픽셀 해상도로 캡처한다. 가려져 있어도 캡처된다.
    /// - Returns: (이미지, point→pixel 스케일)
    static func captureWindow(_ window: SCWindow) async throws -> (image: CGImage, scale: CGFloat) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)

        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true     // 윈도우 정확 경계만 (그림자 제외)

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }
}
