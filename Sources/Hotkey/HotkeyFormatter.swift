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
