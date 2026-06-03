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
        // `.readOnly`(기본값)로 둬서 OBS 등 외부 화면 녹화에는 오버레이(크로스헤어·딤)가 보이게 한다.
        // 우리 루페/스틸 캡처에 자기 자신이 찍히는 자기참조는 `.none`이 아니라
        // SCContentFilter의 `excludingWindows`로 이 윈도우만 골라 제외해 막는다.
        sharingType = .readOnly
        isReleasedWhenClosed = false

        contentView = captureView
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
