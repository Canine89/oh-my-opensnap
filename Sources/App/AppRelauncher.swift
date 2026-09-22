import AppKit

/// 권한 변경 뒤 "앱을 다시 실행하세요"를 사용자에게 시키지 않고 앱이 스스로 재시작한다.
enum AppRelauncher {
    @MainActor
    static func relaunch() {
        // 현재 프로세스가 완전히 내려간 뒤 같은 번들을 연다 (전역 단축키 등록 충돌·두 인스턴스 방지).
        // 종료는 저장 마무리(`.terminateLater`) 때문에 얼마나 걸릴지 모르므로 시간 대신 PID 종료를 기다린다.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = helperArguments(pid: ProcessInfo.processInfo.processIdentifier,
                                         bundlePath: Bundle.main.bundlePath)
        do { try task.run() } catch { return }
        NSApp.terminate(nil)
        // 여기로 돌아왔다면 종료가 취소된 것(저장 실패로 앱을 열어 둠) → 대기 중인 재실행도 취소한다.
        // 두지 않으면 나중에 사용자가 종료할 때 뜻밖에 다시 켜진다.
        if task.isRunning { task.terminate() }
    }

    /// `/bin/sh`에 넘길 인자. PID가 사라질 때까지 기다린 뒤 `open`(‑n 없이)으로 번들을 연다.
    /// `$0` = 번들 경로, `$1` = 기다릴 PID.
    static func helperArguments(pid: Int32, bundlePath: String, openCommand: String = "/usr/bin/open") -> [String] {
        let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; exec \(openCommand) \"$0\""
        return ["-c", script, bundlePath, String(pid)]
    }
}
