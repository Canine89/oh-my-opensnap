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

        copyToClipboard(pngData: pngData)

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

    private static func copyToClipboard(pngData: Data?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let pngData {
            // 클립보드도 저장 파일과 같은 무손실 PNG를 그대로 사용한다.
            // TIFF 폴백은 일부 붙여넣기 대상 앱에서 우선 선택되며, Retina 논리 크기(point)를
            // 거치는 과정에서 축소/리샘플된 것처럼 보일 수 있어 제외한다.
            pasteboard.setData(pngData, forType: .png)
            pasteboard.setData(pngData, forType: NSPasteboard.PasteboardType("com.apple.pboard.type.PNGf"))
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
