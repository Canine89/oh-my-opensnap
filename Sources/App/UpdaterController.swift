import AppKit
import Sparkle

/// Sparkle 자동 업데이트 래퍼.
/// - 앱 시작 시 백그라운드로 새 버전을 확인하고(설정의 SUEnableAutomaticChecks/Interval),
/// - 메뉴의 "업데이트 확인…"으로 즉시 확인할 수 있게 한다.
/// Sparkle의 EdDSA 검증과 Developer ID 서명을 함께 사용한다.
@MainActor
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterController()
    private static let noUpdateErrorCode = 1001
    private static let installationCanceledErrorCode = 4007
    private static let installationAuthorizeLaterErrorCode = 4008

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        // startingUpdater: true → 앱 시작과 함께 업데이터 구동(예약 확인 포함).
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
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

    /// 다운로드·검증·설치 중 오류로 업데이트 주기가 끝나도 다음 자동/수동 확인이
    /// 정상적으로 예약되도록 주기를 복구한다. 취소와 "최신 버전"은 오류가 아니다.
    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        guard let nsError = error as NSError?,
              nsError.domain == SUSparkleErrorDomain,
              nsError.code != Self.noUpdateErrorCode,
              nsError.code != Self.installationCanceledErrorCode,
              nsError.code != Self.installationAuthorizeLaterErrorCode
        else { return }

        NSLog("Sparkle update failed; scheduling a fresh update cycle: %@", nsError)
        updater.resetUpdateCycleAfterShortDelay()
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
