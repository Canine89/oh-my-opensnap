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
}
