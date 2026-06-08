import AppKit
import Sparkle

/// Sparkle 자동 업데이트 래퍼.
/// - 앱 시작 시 백그라운드로 새 버전을 확인하고(설정의 SUEnableAutomaticChecks/Interval),
/// - 메뉴의 "업데이트 확인…"으로 즉시 확인할 수 있게 한다.
/// 비공증(ad-hoc) 앱이라도 Sparkle이 EdDSA 서명으로 무결성을 검증하고,
/// 업데이트 설치 시 quarantine 을 제거하므로 첫 설치 이후엔 경고 없이 갱신된다.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController

    private init() {
        // startingUpdater: true → 앱 시작과 함께 업데이터 구동(예약 확인 포함).
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// 메뉴 "업데이트 확인…" 액션에 연결.
    @objc func checkForUpdates(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(sender)
        bringUpdateWindowsForwardSoon()
    }

    /// 메뉴 항목 활성/비활성 갱신용 (확인 중이면 비활성).
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    private func bringUpdateWindowsForwardSoon() {
        [0.1, 0.4, 0.9, 1.6].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.bringUpdateWindowsForward()
            }
        }
    }

    private func bringUpdateWindowsForward() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .filter(isLikelyUpdateWindow)
            .forEach { window in
                window.level = .modalPanel
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
    }

    private func isLikelyUpdateWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        let title = window.title.lowercased()
        let className = String(describing: type(of: window)).lowercased()
        return className.contains("sparkle")
            || className.contains("update")
            || title.contains("update")
            || title.contains("업데이트")
            || title.contains("새 버전")
            || title.contains("new version")
    }
}
