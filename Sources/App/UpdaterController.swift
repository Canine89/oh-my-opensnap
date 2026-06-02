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
        controller.checkForUpdates(sender)
    }

    /// 메뉴 항목 활성/비활성 갱신용 (확인 중이면 비활성).
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}
