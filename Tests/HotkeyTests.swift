import Carbon.HIToolbox
import XCTest

final class HotkeyValidationTests: XCTestCase {
    private let cmd = UInt32(cmdKey), shift = UInt32(shiftKey)
    private let opt = UInt32(optionKey), ctrl = UInt32(controlKey)

    func testDefaultShortcutIsValid() {
        XCTAssertEqual(HotkeyFormatter.validate(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: cmd | shift), .valid)
    }

    func testShiftAloneIsNotEnough() {
        XCTAssertEqual(HotkeyFormatter.validate(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: shift, character: "A"),
                       .needsModifier)
        XCTAssertEqual(HotkeyFormatter.validate(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: 0), .needsModifier)
        XCTAssertEqual(HotkeyFormatter.validate(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: opt | shift), .valid)
        XCTAssertEqual(HotkeyFormatter.validate(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: ctrl | shift), .valid)
    }

    func testSystemShortcutsAreReserved() {
        let reserved: [(Int, UInt32, String?)] = [
            (kVK_ANSI_Q, cmd, "q"), (kVK_ANSI_W, cmd, "w"), (kVK_ANSI_C, cmd, "c"), (kVK_ANSI_V, cmd, "v"),
            (kVK_ANSI_X, cmd, "x"), (kVK_ANSI_Z, cmd, "z"), (kVK_ANSI_A, cmd, "a"), (kVK_ANSI_Z, cmd | shift, "Z"),
            (kVK_Tab, cmd, "\t"), (kVK_Space, cmd, " "), (kVK_Space, ctrl, " "), (kVK_Escape, cmd | opt, nil),
            (kVK_ANSI_C, cmd, nil)   // 문자 정보 없으면 키코드로 판정
        ]
        for (code, modifiers, character) in reserved {
            XCTAssertEqual(HotkeyFormatter.validate(keyCode: UInt32(code), carbonModifiers: modifiers, character: character),
                           .reserved, "\(code) \(modifiers)")
        }
    }

    func testReservedMatchUsesTypedCharacterAcrossLayouts() {
        // Dvorak 등: ANSI 'C' 자리에서 'j'가 입력되면 ⌘C가 아니다.
        XCTAssertEqual(HotkeyFormatter.validate(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: cmd, character: "j"), .valid)
        // 다른 자리에서 'q'가 입력되면 ⌘Q다.
        XCTAssertEqual(HotkeyFormatter.validate(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: cmd, character: "q"), .reserved)
    }

    func testExtraModifiersMakeCombosAvailable() {
        XCTAssertEqual(HotkeyFormatter.validate(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: cmd | shift, character: "C"), .valid)
        XCTAssertEqual(HotkeyFormatter.validate(keyCode: UInt32(kVK_Space), carbonModifiers: cmd | shift, character: " "), .valid)
    }
}

final class AppRelauncherTests: XCTestCase {
    func testHelperWaitsForProcessExitAndOpensWithoutNewInstanceFlag() throws {
        let arguments = AppRelauncher.helperArguments(pid: 123, bundlePath: "/Applications/A B.app")
        XCTAssertEqual(arguments.first, "-c")
        XCTAssertTrue(arguments[1].contains("kill -0"))
        XCTAssertFalse(arguments[1].contains("open -n"))
        XCTAssertEqual(Array(arguments.dropFirst(2)), ["/Applications/A B.app", "123"])
    }

    func testHelperOpensOnlyAfterTargetExits() throws {
        let target = Process()
        target.executableURL = URL(fileURLWithPath: "/bin/sleep")
        target.arguments = ["0.5"]
        try target.run()

        let output = Pipe()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = AppRelauncher.helperArguments(pid: target.processIdentifier,
                                                         bundlePath: "/tmp/Some App.app",
                                                         openCommand: "/bin/echo")
        helper.standardOutput = output
        try helper.run()

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(helper.isRunning, "대상 프로세스가 살아 있는 동안에는 열지 않는다")
        target.waitUntilExit()

        let deadline = Date().addingTimeInterval(5)
        while helper.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(helper.isRunning)
        let printed = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(printed, "/tmp/Some App.app\n")
    }
}
