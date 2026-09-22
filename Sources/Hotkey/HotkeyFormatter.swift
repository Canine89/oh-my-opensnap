import AppKit
import Carbon.HIToolbox

/// 단축키 표시 문자열 + Cocoa ↔ Carbon modifier 변환.
enum HotkeyFormatter {
    /// Carbon 키코드 + Carbon modifier → "⌘⇧2" 형태.
    static func displayString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { result += "⌘" }
        result += keyName(for: keyCode)
        return result
    }

    /// Cocoa modifier 플래그 → Carbon modifier 마스크.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    /// 전역 단축키 후보 검사 결과.
    enum Validation: Equatable {
        case valid
        /// ⌘ ⌥ ⌃ 중 하나도 없음 (⇧만으로는 일반 타이핑과 겹친다).
        case needsModifier
        /// ⌘Q·⌘C처럼 macOS/모든 앱이 쓰는 조합 — 전역으로 가로채면 시스템 전체가 망가진다.
        case reserved
    }

    /// 녹화한 조합이 전역 단축키로 쓸 만한지 판정한다 (순수 함수 — 테스트 대상).
    /// `character`는 현재 키보드 레이아웃 기준 문자(`charactersIgnoringModifiers`).
    /// 주어지면 문자로, 없으면 ANSI 키코드로 예약 조합을 비교한다.
    static func validate(keyCode: UInt32, carbonModifiers: UInt32, character: String? = nil) -> Validation {
        let required = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        guard carbonModifiers & required != 0 else { return .needsModifier }
        let mods = carbonModifiers & (required | UInt32(shiftKey))
        let typed = character?.lowercased()
        for combo in reservedCombos where combo.modifiers == mods {
            if let char = combo.character, let typed, !typed.isEmpty {
                if typed == char { return .reserved }
            } else if combo.keyCode == Int(keyCode) {
                return .reserved
            }
        }
        return .valid
    }

    /// 시스템·표준 편집 단축키. 문자 키는 레이아웃에 따라 위치가 달라 문자도 함께 둔다.
    private struct ReservedCombo {
        let modifiers: UInt32
        let keyCode: Int
        let character: String?
    }

    private static let reservedCombos: [ReservedCombo] = {
        let cmd = UInt32(cmdKey), shift = UInt32(shiftKey), ctrl = UInt32(controlKey), opt = UInt32(optionKey)
        let letters: [(Int, String)] = [
            (kVK_ANSI_Q, "q"), (kVK_ANSI_W, "w"), (kVK_ANSI_C, "c"), (kVK_ANSI_V, "v"),
            (kVK_ANSI_X, "x"), (kVK_ANSI_Z, "z"), (kVK_ANSI_A, "a"), (kVK_ANSI_S, "s"),
            (kVK_ANSI_H, "h"), (kVK_ANSI_M, "m")
        ]
        var combos = letters.map { ReservedCombo(modifiers: cmd, keyCode: $0.0, character: $0.1) }
        combos += [
            ReservedCombo(modifiers: cmd | shift, keyCode: kVK_ANSI_Z, character: "z"),   // 다시 실행
            ReservedCombo(modifiers: cmd | shift, keyCode: kVK_ANSI_Q, character: "q"),   // 로그아웃
            ReservedCombo(modifiers: cmd, keyCode: kVK_Tab, character: nil),              // 앱 전환
            ReservedCombo(modifiers: cmd | shift, keyCode: kVK_Tab, character: nil),
            ReservedCombo(modifiers: cmd, keyCode: kVK_Space, character: nil),            // Spotlight
            ReservedCombo(modifiers: ctrl, keyCode: kVK_Space, character: nil),           // 입력 소스 전환
            ReservedCombo(modifiers: cmd | opt, keyCode: kVK_Escape, character: nil)      // 강제 종료
        ]
        return combos
    }()

    /// NSMenuItem 표시용 keyEquivalent + Cocoa modifier. (상태 메뉴는 전역 키를 받지 않으므로 표시 전용)
    static func menuKeyEquivalent(keyCode: UInt32, carbonModifiers: UInt32) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey)  != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey)   != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey)     != 0 { flags.insert(.command) }
        if let special = menuSpecialKeys[Int(keyCode)] { return (special, flags) }
        guard let char = characterForKeyCode(keyCode), char.count == 1 else { return nil }
        return (char.lowercased(), flags)
    }

    private static func functionKey(_ code: Int) -> String {
        String(utf16CodeUnits: [unichar(code)], count: 1)
    }

    private static let menuSpecialKeys: [Int: String] = [
        kVK_Return: "\r", kVK_Tab: "\t", kVK_Space: " ", kVK_Delete: "\u{8}", kVK_Escape: "\u{1B}",
        kVK_ForwardDelete: functionKey(NSDeleteFunctionKey),
        kVK_LeftArrow: functionKey(NSLeftArrowFunctionKey), kVK_RightArrow: functionKey(NSRightArrowFunctionKey),
        kVK_UpArrow: functionKey(NSUpArrowFunctionKey), kVK_DownArrow: functionKey(NSDownArrowFunctionKey),
        kVK_F1: functionKey(NSF1FunctionKey), kVK_F2: functionKey(NSF2FunctionKey), kVK_F3: functionKey(NSF3FunctionKey),
        kVK_F4: functionKey(NSF4FunctionKey), kVK_F5: functionKey(NSF5FunctionKey), kVK_F6: functionKey(NSF6FunctionKey),
        kVK_F7: functionKey(NSF7FunctionKey), kVK_F8: functionKey(NSF8FunctionKey), kVK_F9: functionKey(NSF9FunctionKey),
        kVK_F10: functionKey(NSF10FunctionKey), kVK_F11: functionKey(NSF11FunctionKey), kVK_F12: functionKey(NSF12FunctionKey)
    ]

    private static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }
        // 일반 키는 현재 키보드 레이아웃으로 문자 변환
        if let char = characterForKeyCode(keyCode) { return char.uppercased() }
        return "?"
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "␣", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12"
    ]

    private static func characterForKeyCode(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = unsafeBitCast(layoutData, to: CFData.self)
        let keyLayoutPtr = CFDataGetBytePtr(data)
        return keyLayoutPtr?.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout -> String? in
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout,
                                        UInt16(keyCode),
                                        UInt16(kUCKeyActionDisplay),
                                        0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState,
                                        chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
