import AppKit

/// 캡처한 이미지를 활성 AI 에이전트의 채팅 세션에 붙여넣는다.
/// 클립보드에 이미지가 올라간 뒤: 호스트 앱 활성화 → 붙여넣기 키(CLI ⌃V / GUI ⌘V) 전송.
/// 키 이벤트 전송에는 접근성 권한이 필요하다(없으면 안내만 하고 이미지는 클립보드에 남는다).
@MainActor
final class AgentPasteService {
    static let shared = AgentPasteService()
    private init() {}

    /// 캡처 모드 진입 직전의 프론트 앱 — 여러 에이전트 중 기본 대상을 고르는 기준.
    private(set) var frontmostPIDBeforeCapture: pid_t?
    private var activationTimer: Timer?

    /// 오버레이가 우리 앱을 활성화하기 전에 불러, 사용자가 직전까지 보던 앱을 기억해 둔다.
    func noteFrontmostBeforeCapture() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
        frontmostPIDBeforeCapture = front.processIdentifier
    }

    func detectSessions() -> [AgentSession] {
        AgentSessionDetector.detect(preferredHostPID: frontmostPIDBeforeCapture)
    }

    /// 자동 붙여넣기 대상: 캡처 직전 프론트 앱이 호스트인 세션 우선, 없으면 첫 번째.
    func bestSession() -> AgentSession? {
        detectSessions().first
    }

    func paste(into session: AgentSession) {
        #if !MAS
        guard AccessibilityPermission.isGranted else {
            AccessibilityPermission.request()
            showPermissionGuide(for: session)
            return
        }

        activationTimer?.invalidate()
        let app = session.hostApp
        NSApp.yieldActivation(to: app)
        app.activate()

        // 활성화는 비동기라 프론트가 될 때까지 짧게 기다렸다가 키를 보낸다.
        var attempts = 0
        activationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                attempts += 1
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                    timer.invalidate()
                    self?.activationTimer = nil
                    // 활성화 직후 첫 키 입력을 놓치는 앱이 있어 한 박자 뒤에 보낸다.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        Self.postPasteKeystroke(kind: session.kind)
                    }
                } else if attempts >= 30 {   // ≈1.5초
                    timer.invalidate()
                    self?.activationTimer = nil
                    NSLog("AgentPaste: \(session.displayName) 활성화 실패 — 붙여넣기 생략 (클립보드엔 복사됨)")
                }
            }
        }
        #endif
    }

    #if !MAS
    /// CLI 에이전트(Claude Code 등)는 터미널에서 ⌃V로 클립보드 이미지를 읽고,
    /// GUI 앱은 표준 ⌘V를 쓴다.
    private static func postPasteKeystroke(kind: AgentSession.Kind) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let flags: CGEventFlags = (kind == .cli) ? .maskControl : .maskCommand
        let keyV: CGKeyCode = 9   // kVK_ANSI_V
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: keyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private func showPermissionGuide(for session: AgentSession) {
        let alert = NSAlert()
        alert.messageText = "에이전트 붙여넣기에는 접근성 권한이 필요합니다"
        alert.informativeText = """
        \(session.displayName)에 붙여넣기 키를 보내려면 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 \(Brand.name)을 허용하세요.

        캡처한 이미지는 이미 클립보드에 있으니, 지금은 에이전트 입력창에서 직접 붙여넣을 수 있습니다(터미널 ⌃V · 앱 ⌘V).
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "닫기")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            AccessibilityPermission.openSystemSettings()
        }
    }
    #endif
}
