import AppKit

/// 한 디스플레이를 전부 덮는 투명·보더리스 캡처 윈도우.
final class OverlayWindow: NSWindow {
    let captureView: OverlayView

    init(screen: NSScreen) {
        captureView = OverlayView()
        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // 메뉴바·Dock 위는 덮되, 시스템 다이얼로그(TCC 권한 prompt 등)보다는 낮게 둔다.
        // CGShieldingWindowLevel()은 시스템 prompt보다도 위라, prompt가 차폐막 뒤에 깔리면
        // 커서가 숨겨진 채 입력이 전부 막혀 OS 전체가 잠긴 것처럼 보인다(강제 재부팅 유발).
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        sharingType = .none            // ScreenCaptureKit 캡처에서 제외 (루페/스크린샷에 안 찍힘)
        isReleasedWhenClosed = false

        contentView = captureView
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
