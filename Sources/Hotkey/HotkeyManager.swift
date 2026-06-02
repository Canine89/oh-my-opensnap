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

    private init() {}

    /// 앱 시작 시 1회 호출 — 이벤트 핸들러 설치 + 현재 설정으로 등록.
    func start() {
        installHandlerIfNeeded()
        registerCurrent()
    }

    /// 설정 변경 후 재등록.
    func reload() {
        unregisterHotKey()
        registerCurrent()
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
            DispatchQueue.main.async { manager.onTrigger?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        installed = true
    }

    private func registerCurrent() {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("ARZR"), id: 1)
        RegisterEventHotKey(Settings.shared.hotKeyCode,
                            Settings.shared.hotKeyModifiers,
                            hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
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
