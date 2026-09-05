import AppKit

/// 권한 변경 뒤 "앱을 다시 실행하세요"를 사용자에게 시키지 않고 앱이 스스로 재시작한다.
#if !MAS
enum AppRelauncher {
    @MainActor
    static func relaunch() {
        // 현재 프로세스가 완전히 내려간 뒤 같은 번들을 새로 연다 (전역 단축키 등록 충돌 방지).
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
#endif
