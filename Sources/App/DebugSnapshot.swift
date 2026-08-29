#if DEBUG
import AppKit
import ScreenCaptureKit

/// 개발용: 창을 PNG로 저장한다. 1순위는 윈도우 서버 합성 결과(재질·그림자 포함),
/// 화면 녹화 권한이 없으면 뷰 계층 렌더로 대체한다(레이아웃·간격 검토용).
enum DebugSnapshot {
    @MainActor
    static func write(window: NSWindow, to path: String) async {
        let windowID = CGWindowID(window.windowNumber)
        let url = URL(fileURLWithPath: path)
        if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
           let scWindow = content.windows.first(where: { $0.windowID == windowID }),
           let result = try? await StillImageCapturer.captureWindow(scWindow) {
            let rep = NSBitmapImageRep(cgImage: result.image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        } else if let frameView = window.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
#endif
