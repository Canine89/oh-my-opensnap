import AppKit
import Carbon.HIToolbox

/// Carbon `RegisterEventHotKey` 기반 전역 단축키.
/// 접근성 권한이 필요 없고 App Sandbox에서도 동작한다.
/// 단축키 값은 Settings에 저장되며 `reload()`로 즉시 갱신할 수 있다.
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var installed = false

    /// 마지막 등록 시도의 실패 코드. nil이면 등록 성공(또는 아직 시도 전).
    /// 다른 앱·시스템이 같은 조합을 선점하면 `eventHotKeyExistsErr`가 온다.
    private(set) var lastRegistrationError: OSStatus?

    /// 현재 설정의 단축키가 실제로 등록돼 있는지 (녹화 중 일시 해제 상태는 false).
    var isRegistered: Bool { hotKeyRef != nil }

    /// 등록을 시도했는데 실패한 상태 — 메뉴·설정 창이 "사용 불가"로 표시한다.
    var registrationFailed: Bool { lastRegistrationError != nil }

    private init() {}

    /// 앱 시작 시 1회 호출 — 이벤트 핸들러 설치 + 현재 설정으로 등록.
    func start() {
        installHandlerIfNeeded()
        registerCurrent()
    }

    /// 설정 변경 후 재등록. 등록에 성공하면 true.
    @discardableResult
    func reload() -> Bool {
        unregisterHotKey()
        return registerCurrent()
    }

    /// 단축키 녹화 중 일시 해제 — 등록된 단축키가 녹화 입력을 가로채지 않도록.
    /// 녹화 종료 시 `reload()`로 복구한다.
    func suspend() {
        unregisterHotKey()
    }

    func stop() {
        unregisterHotKey()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        installed = false
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon 앱 이벤트 핸들러는 메인 스레드에서 호출된다. 다음 런루프로
            // 미루지 않아야 메뉴 강조가 바뀌기 전에 화면 확보를 요청할 수 있다.
            MainActor.assumeIsolated { manager.onTrigger?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        installed = true
    }

    @discardableResult
    private func registerCurrent() -> Bool {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("ARZR"), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(Settings.shared.hotKeyCode,
                                         Settings.shared.hotKeyModifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        // 실패를 삼키면 단축키가 없는데도 UI는 등록된 것처럼 보인다 → 상태를 남겨 표시한다.
        if status == noErr, let ref {
            hotKeyRef = ref
            lastRegistrationError = nil
            return true
        }
        hotKeyRef = nil
        lastRegistrationError = status == noErr ? OSStatus(eventInternalErr) : status
        NSLog("[Hotkey] RegisterEventHotKey 실패: %d", status)
        return false
    }

    private func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    deinit { stop() }
}

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("com.goldenrabbit.appresizer.hotkeyChanged")
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars where scalar.isASCII {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}
