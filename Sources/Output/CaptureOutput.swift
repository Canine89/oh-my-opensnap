import AppKit

/// 캡처 결과를 클립보드에 복사하고(핵심 기능), 옵션에 따라 파일 저장 + HUD 표시.
@MainActor
enum CaptureOutput {
    static func deliver(cgImage: CGImage, scale: CGFloat) {
        // 논리 크기(point)를 지정해 붙여넣기 시 올바른 크기로 들어가게 한다.
        let logicalSize = NSSize(width: CGFloat(cgImage.width) / scale,
                                 height: CGFloat(cgImage.height) / scale)
        let image = NSImage(cgImage: cgImage, size: logicalSize)

        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = logicalSize
        let pngData = rep.representation(using: .png, properties: [:])

        copyToClipboard(image: image, pngData: pngData)

        if let pngData {
            // 라이브러리에 항상 보관 (다시 보기용)
            CaptureLibrary.shared.save(pngData: pngData, date: Date())
            // 사용자 지정 폴더로 별도 내보내기 (옵션)
            if Settings.shared.saveToFile {
                saveToFile(pngData)
            }
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

    private static func saveToFile(_ pngData: Data) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let filename = "\(formatter.string(from: Date())).png"
        let url = Settings.shared.saveDirectory.appendingPathComponent(filename)
        do {
            try pngData.write(to: url)
        } catch {
            NSLog("Save failed: \(error)")
        }
    }
}
