import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 편집기에 얹을 이미지 한 장: 첫 프레임(첫 페이지)의 픽셀 + 논리 배율(픽셀 ÷ point).
/// 배율은 캡처의 픽셀 공간으로 옮길 때 "원래 보이던 크기"를 유지하는 데만 쓴다.
struct InsertableImage {
    let cgImage: CGImage
    let scale: CGFloat

    /// 받아들이는 파일: 비트맵 이미지 전반(PNG·JPEG·HEIC·TIFF·GIF 첫 프레임) + PDF 첫 페이지.
    static let acceptedTypes: [UTType] = [.image, .pdf]
    /// 한 변 상한. 초대형 원본이 메모리를 잡아먹지 않게 한다(얹을 때는 어차피 캔버스 60% 이하로 줄어든다).
    static let maxPixelSize = 8192

    /// 파일 바이트에서 첫 프레임을 방향(EXIF) 보정해 읽는다. DPI가 없으면 72dpi(배율 1)로 본다.
    static func decode(data: Data) -> InsertableImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           width > 0, height > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPixelSize),
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
                // 긴 변 기준 논리 길이(point). 상한으로 줄였으면 배율이 그만큼 작아져 논리 크기는 그대로다.
                let logicalLong = CGFloat(max(width, height)) * 72 / CGFloat(dpi > 0 ? dpi : 72)
                return InsertableImage(cgImage: cg, scale: PNGEncoding.scale(pixelWidth: max(cg.width, cg.height),
                                                                             logicalWidth: logicalLong))
            }
        }
        // ImageIO가 못 읽는 형식(PDF 등)은 NSImage로 그린다.
        return NSImage(data: data).flatMap { from(image: $0) }
    }

    /// 클립보드 NSImage: 논리 크기는 NSImage의 size(point)를 따른다.
    static func from(image: NSImage) -> InsertableImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        if image.representations.contains(where: { $0 is NSBitmapImageRep }),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return InsertableImage(cgImage: cg, scale: PNGEncoding.scale(pixelWidth: cg.width, logicalWidth: size.width))
        }
        // 벡터(PDF 등)는 2배로 래스터화해 Retina 캡처 위에서도 선명하게 얹는다.
        let rasterScale = min(2, CGFloat(maxPixelSize) / max(size.width, size.height))
        let width = max(1, Int((size.width * rasterScale).rounded()))
        let height = max(1, Int((size.height * rasterScale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return InsertableImage(cgImage: cg, scale: PNGEncoding.scale(pixelWidth: width, logicalWidth: size.width))
    }

    /// 붙여넣기·드롭 공통. 파일 URL이 있으면 파일만 본다 — Finder 복사에 딸려 오는 아이콘 TIFF를 얹지 않기 위해.
    static func read(from pasteboard: NSPasteboard) -> InsertableImage? {
        if hasFileURLs(pasteboard) {
            guard let url = imageFileURLs(in: pasteboard).first else { return nil }
            do { return decode(data: try Data(contentsOf: url)) }
            catch {
                NSLog("Insert image failed for %@: %@", url.lastPathComponent, error.localizedDescription)
                return nil
            }
        }
        return NSImage(pasteboard: pasteboard).flatMap { from(image: $0) }
    }

    /// 디코딩 없이 받아들일 수 있는지만 본다(드래그가 지나가는 동안 반복 호출).
    static func canRead(from pasteboard: NSPasteboard) -> Bool {
        if hasFileURLs(pasteboard) { return !imageFileURLs(in: pasteboard).isEmpty }
        return NSImage.canInit(with: pasteboard)
    }

    private static func hasFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private static func imageFileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: acceptedTypes.map(\.identifier)
        ]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

/// 얹을 이미지의 크기·위치 계산(순수 함수). 좌표는 캡처 픽셀, 좌상단 원점.
enum ImageInsertionLayout {
    /// 처음 얹을 때 캔버스 가로·세로 대비 최대 비율.
    static let maxCanvasFraction: CGFloat = 0.6

    /// 원본의 논리 크기(픽셀 ÷ 원본 배율)를 캡처 배율로 픽셀화하고, 캔버스의 60%를 넘으면 비율대로 줄인다.
    static func size(pixelSize: CGSize, sourceScale: CGFloat, targetScale: CGFloat, canvas: CGSize) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        let source = sourceScale.isFinite && sourceScale > 0 ? sourceScale : 1
        let target = targetScale.isFinite && targetScale > 0 ? targetScale : 1
        var width = pixelSize.width / source * target
        var height = pixelSize.height / source * target
        let limitW = canvas.width * maxCanvasFraction
        let limitH = canvas.height * maxCanvasFraction
        if limitW > 0, limitH > 0 {
            let fit = min(1, limitW / width, limitH / height)
            width *= fit
            height *= fit
        }
        return CGSize(width: max(1, width.rounded()), height: max(1, height.rounded()))
    }

    /// `center`를 중심으로 놓되, 가능하면 캔버스 안에 완전히 들어오게 민다.
    static func rect(size: CGSize, centeredAt center: CGPoint, canvas: CGSize) -> CGRect {
        func place(_ mid: CGFloat, _ length: CGFloat, _ limit: CGFloat) -> CGFloat {
            let origin = (mid - length / 2).rounded()
            return length <= limit ? min(max(0, origin), limit - length) : 0
        }
        return CGRect(x: place(center.x, size.width, canvas.width),
                      y: place(center.y, size.height, canvas.height),
                      width: size.width, height: size.height)
    }

    /// 비율을 지킨 모서리 크기 조절: 반대편 모서리를 고정하고, 커서까지의 가로·세로 배율 중 큰 쪽을 따른다.
    /// 잡은 방향으로만 자라(뒤집히지 않음) 캔버스 밖으로 나가지 않으며, 짧은 변은 최소 8px.
    static func aspectResizedRect(_ r: CGRect, fixed: CGPoint, toward point: CGPoint, within canvas: CGRect) -> CGRect {
        guard r.width > 0, r.height > 0 else { return r }
        let dirX: CGFloat = fixed.x <= r.midX ? 1 : -1      // 잡은 모서리는 고정점의 반대편
        let dirY: CGFloat = fixed.y <= r.midY ? 1 : -1
        let sx = max(0, (point.x - fixed.x) * dirX) / r.width
        let sy = max(0, (point.y - fixed.y) * dirY) / r.height
        let roomX = dirX > 0 ? canvas.maxX - fixed.x : fixed.x - canvas.minX
        let roomY = dirY > 0 ? canvas.maxY - fixed.y : fixed.y - canvas.minY
        var s = min(max(sx, sy), roomX / r.width, roomY / r.height)
        s = max(s, 8 / min(r.width, r.height))
        let width = r.width * s
        let height = r.height * s
        return CGRect(x: dirX > 0 ? fixed.x : fixed.x - width,
                      y: dirY > 0 ? fixed.y : fixed.y - height,
                      width: width, height: height)
    }
}
