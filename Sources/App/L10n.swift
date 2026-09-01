import Foundation

/// 앱 표시 언어. 시스템 언어와 무관하게 앱 안에서 선택한다 (기본: 영어).
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case korean = "ko"

    /// 언어 선택 UI에 보여줄 자기 언어 이름 (항상 그 언어로 표기).
    var displayName: String {
        switch self {
        case .english: return "English"
        case .korean: return "한국어"
        }
    }
}

extension Notification.Name {
    /// 앱 언어가 바뀌었을 때. 메뉴 막대·열린 창들이 받아서 문자열을 다시 그린다.
    static let appLanguageDidChange = Notification.Name("com.goldenrabbit.ohmyopensnap.appLanguageDidChange")
}

extension Settings {
    private static let appLanguageKey = "appLanguage"

    /// 저장된 언어. 기본값은 영어 — 첫 실행 온보딩에서 한국어로 바꿀 수 있다.
    var appLanguage: AppLanguage {
        get {
            if let raw = UserDefaults.standard.string(forKey: Self.appLanguageKey),
               let lang = AppLanguage(rawValue: raw) {
                return lang
            }
            return .english
        }
        set {
            guard newValue != appLanguage else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.appLanguageKey)
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        }
    }
}

/// 현재 앱 언어에 맞는 문자열을 고른다. 번역은 사용처에 나란히 둔다.
/// 예: `loc("Capture Area", "영역 캡처")`
func loc(_ english: String, _ korean: String) -> String {
    Settings.shared.appLanguage == .korean ? korean : english
}
