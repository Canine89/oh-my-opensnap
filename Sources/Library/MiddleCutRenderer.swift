import AppKit

enum MiddleCutAxis {
    case verticalStrip
    case horizontalStrip
}

/// 이미지의 가로 또는 세로 중간 띠를 제거하고, 남은 두 조각 사이를 투명하게 합성한다.
enum MiddleCutRenderer {
    static func makeImage(source: CGImage, axis: MiddleCutAxis,
                          cutStart: Int, cutEnd: Int,
                          transparentGap: Int) -> NSImage? {
        let sourceWidth = source.width
        let sourceHeight = source.height
        let removedLength = cutEnd - cutStart
        let outputWidth = axis == .verticalStrip
            ? sourceWidth - removedLength + transparentGap : sourceWidth
        let outputHeight = axis == .horizontalStrip
            ? sourceHeight - removedLength + transparentGap : sourceHeight
        guard cutStart >= 0, cutEnd > cutStart,
              (axis == .verticalStrip ? cutEnd <= sourceWidth : cutEnd <= sourceHeight),
              transparentGap >= 0, outputWidth > 0, outputHeight > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: outputWidth, height: outputHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // 빈 캔버스는 투명(0 alpha)으로 두고, 남은 두 조각만 원래 크기로 옮겨 그린다.
        context.translateBy(x: 0, y: CGFloat(outputHeight))
        context.scaleBy(x: 1, y: -1)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        let image = NSImage(cgImage: source,
                            size: NSSize(width: sourceWidth, height: sourceHeight))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        switch axis {
        case .verticalStrip:
            let rightWidth = sourceWidth - cutEnd
            drawImagePiece(image, clip: CGRect(x: 0, y: 0, width: cutStart, height: sourceHeight),
                           imageOrigin: .zero, sourceSize: image.size)
            let rightX = cutStart + transparentGap
            drawImagePiece(image,
                           clip: CGRect(x: rightX, y: 0, width: rightWidth, height: sourceHeight),
                           imageOrigin: CGPoint(x: rightX - cutEnd, y: 0), sourceSize: image.size)
        case .horizontalStrip:
            let bottomHeight = sourceHeight - cutEnd
            drawImagePiece(image, clip: CGRect(x: 0, y: 0, width: sourceWidth, height: cutStart),
                           imageOrigin: .zero, sourceSize: image.size)
            let bottomY = cutStart + transparentGap
            drawImagePiece(image,
                           clip: CGRect(x: 0, y: bottomY, width: sourceWidth, height: bottomHeight),
                           imageOrigin: CGPoint(x: 0, y: bottomY - cutEnd), sourceSize: image.size)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: outputWidth, height: outputHeight))
    }

    private static func drawImagePiece(_ image: NSImage, clip: CGRect,
                                       imageOrigin: CGPoint, sourceSize: NSSize) {
        guard !clip.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clip).addClip()
        image.draw(in: CGRect(origin: imageOrigin, size: sourceSize))
        NSGraphicsContext.restoreGraphicsState()
    }
}
