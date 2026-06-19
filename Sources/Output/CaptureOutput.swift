import AppKit

/// 캡처 결과를 클립보드에 복사하고(핵심 기능), 저장 폴더에 보관 + HUD 표시.
@MainActor
enum CaptureOutput {
    static func deliver(cgImage: CGImage, scale: CGFloat) {
        // 논리 크기(point)를 지정해 붙여넣기 시 올바른 크기로 들어가게 한다.
        let logicalSize = NSSize(width: CGFloat(cgImage.width) / scale,
                                 height: CGFloat(cgImage.height) / scale)
        let image = NSImage(cgImage: cgImage, size: logicalSize)

        let pngData = pngDataPreservingAlpha(from: cgImage, logicalSize: logicalSize)

        copyToClipboard(image: image, pngData: pngData)

        if let pngData {
            // 저장 폴더(기본: 바탕화면/oh-my-opensnap, 설정에서 변경 가능)에 보관
            CaptureLibrary.shared.save(pngData: pngData, date: Date())
            // 캡처 완료 → 라이브러리 자동 열기 (방금 캡처한 최신 항목을 선택해 보여줌)
            LibraryWindowController.shared.showWindowSelectingLatest()
        }

        if Settings.shared.playSound {
            NSSound(named: NSSound.Name("Pop"))?.play()
        }

        ThumbnailHUD.show(image)
    }

    private static func copyToClipboard(image: NSImage, pngData: Data?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let pngData {
            // 모던 PNG + 레거시 PNGf + TIFF 폴백으로 호환성 최대화
            pasteboard.setData(pngData, forType: .png)
            pasteboard.setData(pngData, forType: NSPasteboard.PasteboardType("com.apple.pboard.type.PNGf"))
        }
        if let tiff = image.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    private static func pngDataPreservingAlpha(from cgImage: CGImage, logicalSize: NSSize) -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: cgImage.width,
                                      height: cgImage.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            let fallback = NSBitmapImageRep(cgImage: cgImage)
            fallback.size = logicalSize
            return fallback.representation(using: .png, properties: [:])
        }

        let rect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        context.clear(rect)
        context.draw(cgImage, in: rect)
        guard let normalized = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: normalized)
        rep.size = logicalSize
        return rep.representation(using: .png, properties: [:])
    }
}
