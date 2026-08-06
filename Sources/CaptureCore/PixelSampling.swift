import CoreVideo
import CoreGraphics
import Foundation

struct SampledRegion {
    let image: CGImage
    let centerColor: (r: UInt8, g: UInt8, b: UInt8)
}

/// BGRA 픽셀 버퍼에서 커서 주변 정사각형 영역만 잘라 작은 CGImage로 만든다.
/// 전체 프레임을 변환하지 않으므로 60fps 루페에서도 가볍다.
enum PixelSampling {
    /// - Parameters:
    ///   - centerX/centerY: 픽셀 좌표(좌상단 기준)
    ///   - radius: 중심 양옆으로 샘플링할 소스 픽셀 수 → 한 변 (2*radius+1)
    static func sample(_ buffer: CVPixelBuffer, centerX: Int, centerY: Int, radius: Int) -> SampledRegion? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let srcStride = CVPixelBufferGetBytesPerRow(buffer)
        let srcPtr = base.assumingMemoryBound(to: UInt8.self)

        let side = radius * 2 + 1
        let dstStride = side * 4
        var dst = [UInt8](repeating: 0, count: dstStride * side)

        for row in 0..<side {
            let sy = centerY - radius + row
            if sy < 0 || sy >= height { continue }
            for col in 0..<side {
                let sx = centerX - radius + col
                if sx < 0 || sx >= width { continue }
                let srcOffset = sy * srcStride + sx * 4
                let dstOffset = row * dstStride + col * 4
                dst[dstOffset + 0] = srcPtr[srcOffset + 0] // B
                dst[dstOffset + 1] = srcPtr[srcOffset + 1] // G
                dst[dstOffset + 2] = srcPtr[srcOffset + 2] // R
                dst[dstOffset + 3] = 255                   // A
            }
        }

        // 중심 픽셀 색상 (dst는 BGRA 순서)
        let centerOffset = radius * dstStride + radius * 4
        let centerColor = (r: dst[centerOffset + 2],
                           g: dst[centerOffset + 1],
                           b: dst[centerOffset + 0])

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // 메모리 순서 BGRA == little-endian 32bit ARGB(premultipliedFirst)
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let provider = CGDataProvider(data: Data(dst) as CFData),
              let image = CGImage(width: side,
                                  height: side,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: dstStride,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return nil }

        return SampledRegion(image: image, centerColor: centerColor)
    }

    /// 정지 화면(CGImage)에서 커서 주변 정사각형 영역을 잘라낸다.
    /// 좌표는 CGImage와 같은 좌상단 원점 픽셀 좌표. 화면 밖으로 나간 부분은 비워 둔다.
    static func sample(_ image: CGImage, centerX: Int, centerY: Int, radius: Int) -> SampledRegion? {
        let side = radius * 2 + 1
        let dstStride = side * 4
        // 메모리 순서 BGRA == little-endian 32bit ARGB(premultipliedFirst) — 스트림 경로와 동일.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil,
                                  width: side,
                                  height: side,
                                  bitsPerComponent: 8,
                                  bytesPerRow: dstStride,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo)
        else { return nil }
        ctx.interpolationQuality = .none

        let requested = CGRect(x: centerX - radius, y: centerY - radius, width: side, height: side)
        let visible = requested.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !visible.isEmpty, let piece = image.cropping(to: visible) {
            // 컨텍스트는 좌하단 원점이라 위에서 잰 오프셋을 아래 기준으로 뒤집는다.
            let insetTop = visible.minY - requested.minY
            ctx.draw(piece, in: CGRect(x: visible.minX - requested.minX,
                                       y: CGFloat(side) - insetTop - visible.height,
                                       width: visible.width,
                                       height: visible.height))
        }

        guard let data = ctx.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let centerOffset = radius * dstStride + radius * 4
        let centerColor = (r: pixels[centerOffset + 2],
                           g: pixels[centerOffset + 1],
                           b: pixels[centerOffset + 0])

        guard let region = ctx.makeImage() else { return nil }
        return SampledRegion(image: region, centerColor: centerColor)
    }
}
