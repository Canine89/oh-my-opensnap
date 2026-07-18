import ScreenCaptureKit
import CoreGraphics

/// 최종 캡처용 정지 이미지. 구 `CGWindowListCreateImage`를 대체하는
/// `SCScreenshotManager`로 디스플레이를 풀 픽셀 해상도로 1장 캡처한다.
enum StillImageCapturer {
    enum CaptureError: Error { case noImage }

    /// 디스플레이의 일부(또는 전체)를 캡처한다.
    /// `sourceRect`(디스플레이 좌상단 기준 point)가 있으면 그 영역만 요청하고,
    /// 실패하거나 결과가 기대와 다르면 전체 캡처 후 crop으로 폴백한다.
    static func capture(display: SCDisplay,
                        scale: CGFloat,
                        sourceRect: CGRect? = nil,
                        excluding: [SCWindow] = []) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: excluding)

        if let sourceRect, sourceRect.width > 2, sourceRect.height > 2 {
            let integral = sourceRect.integral
            if let cropped = try? await captureRegion(filter: filter, scale: scale, sourceRect: integral) {
                let expectedW = Int((integral.width * scale).rounded())
                let expectedH = Int((integral.height * scale).rounded())
                // 허용 오차 2px — sourceRect 경로가 유효하면 그대로 반환.
                if abs(cropped.width - expectedW) <= 2, abs(cropped.height - expectedH) <= 2 {
                    return cropped
                }
            }
        }

        let full = try await captureFull(filter: filter, display: display, scale: scale)
        guard let sourceRect, sourceRect.width > 2, sourceRect.height > 2 else { return full }

        let pxRect = CGRect(x: sourceRect.minX * scale,
                            y: sourceRect.minY * scale,
                            width: sourceRect.width * scale,
                            height: sourceRect.height * scale).integral
        let bounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
        let clamped = pxRect.intersection(bounds)
        guard !clamped.isEmpty, let crop = full.cropping(to: clamped) else {
            throw CaptureError.noImage
        }
        return crop
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

    private static func captureRegion(filter: SCContentFilter,
                                      scale: CGFloat,
                                      sourceRect: CGRect) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = max(2, Int((sourceRect.width * scale).rounded()))
        config.height = max(2, Int((sourceRect.height * scale).rounded()))
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func captureFull(filter: SCContentFilter,
                                    display: SCDisplay,
                                    scale: CGFloat) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
