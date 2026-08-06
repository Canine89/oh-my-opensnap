import AppKit

/// 한 디스플레이를 전부 덮는 투명·보더리스 캡처 윈도우.
/// `frozenImage`가 있으면 진입 순간의 정지 화면을 배경 레이어로 깔아, 뒤 화면이 재생 중이어도
/// 멈춘 화면에서 영역을 고를 수 있게 한다. 딤·크로스헤어를 그리는 `captureView`는 그 위에 얹힌다.
final class OverlayWindow: NSWindow {
    let captureView: OverlayView

    init(screen: NSScreen, frozenImage: CGImage? = nil) {
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

        // 컨테이너/각 뷰를 레이어 백드로 둬야 captureView의 `ctx.clear`가
        // 아래에 깔린 정지 화면을 지우지 않고 투명하게 비춘다(윈도우 하이라이트 포함).
        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true
        container.autoresizesSubviews = true

        if let frozenImage {
            let frozenView = NSView(frame: container.bounds)
            frozenView.autoresizingMask = [.width, .height]
            frozenView.wantsLayer = true
            frozenView.layer?.contents = frozenImage
            frozenView.layer?.contentsGravity = .resize      // 픽셀 이미지를 point 크기 레이어에 1:1로
            frozenView.layer?.contentsScale = screen.backingScaleFactor
            frozenView.layer?.magnificationFilter = .nearest
            container.addSubview(frozenView)
        }

        captureView.frame = container.bounds
        captureView.autoresizingMask = [.width, .height]
        captureView.wantsLayer = true
        container.addSubview(captureView)

        contentView = container
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
