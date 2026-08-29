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

    /// 적어도 하나의 modifier가 있어야 전역 단축키로 유효.
    static func hasModifier(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection([.control, .option, .shift, .command]).isEmpty
    }

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
