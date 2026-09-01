import AppKit
import Darwin

/// 캡처를 붙여넣을 수 있는, 실행 중인 AI 에이전트 세션 하나.
struct AgentSession {
    enum Kind {
        /// 터미널에서 도는 CLI 에이전트 — 이미지 붙여넣기 키가 ⌃V.
        case cli
        /// 자체 창을 가진 데스크톱 앱 — 붙여넣기 키가 ⌘V.
        case gui
    }

    let agentName: String
    let kind: Kind
    /// CLI면 터미널(호스트) 앱, GUI면 에이전트 앱 자신. 활성화·아이콘의 기준.
    let hostApp: NSRunningApplication

    var displayName: String {
        switch kind {
        case .cli: return "\(agentName) — \(hostApp.localizedName ?? "터미널")"
        case .gui: return agentName
        }
    }

    var icon: NSImage? { hostApp.icon }
}

/// 실행 중인 프로세스에서 AI 에이전트 세션을 찾는다.
/// CLI 에이전트는 프로세스 이름(또는 node 같은 인터프리터의 argv)으로 식별하고,
/// 부모 프로세스를 따라가 키 입력을 보낼 호스트 GUI 앱(터미널·에디터)을 정한다.
/// tmux 등 데몬 아래에서 도는 세션은 호스트 창을 특정할 수 없어 제외된다.
@MainActor
enum AgentSessionDetector {
    /// 실행 파일 이름 → 표시 이름. p_comm(16자 제한)과 인터프리터 argv 양쪽에서 찾는다.
    private static let cliAgents: [String: String] = [
        "claude": "Claude Code",
        "codex": "Codex CLI",
        "gemini": "Gemini CLI",
        "aider": "Aider",
        "opencode": "opencode",
        "goose": "Goose",
        "amp": "Amp",
        "cursor-agent": "Cursor Agent",
        "copilot": "Copilot CLI",
    ]

    /// 스크립트로 배포되는 CLI는 프로세스 이름이 인터프리터로 잡힌다 → argv에서 실제 이름을 찾는다.
    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]

    /// 자체 채팅 창을 가진 데스크톱 에이전트 앱.
    private static let guiAgents: [String: String] = [
        "com.anthropic.claudefordesktop": "Claude",
        "com.openai.chat": "ChatGPT",
    ]

    /// 현재 사용자 소유 프로세스에서 에이전트 세션을 모은다.
    /// `preferredHostPID`(캡처 직전 프론트 앱)가 호스트인 세션을 앞에 둔다.
    static func detect(preferredHostPID: pid_t?) -> [AgentSession] {
        #if MAS
        // 샌드박스는 다른 앱으로 키 입력을 보낼 수 없다 — 기능 자체를 노출하지 않는다.
        return []
        #else
        var sessions: [AgentSession] = []
        var seen = Set<String>()

        let regularApps = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first })

        let procs = allProcesses()
        let parents = Dictionary(procs.map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) },
                                 uniquingKeysWith: { first, _ in first })
        let uid = getuid()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for proc in procs {
            let pid = proc.kp_proc.p_pid
            guard pid > 0, pid != ownPID, proc.kp_eproc.e_ucred.cr_uid == uid else { continue }

            let name = commName(proc)
            var agentName = cliAgents[name]
            if agentName == nil, interpreters.contains(name) {
                agentName = agentNameFromArguments(pid: pid)
            }
            guard let agentName else { continue }
            guard let host = hostApp(for: pid, parents: parents, apps: regularApps) else { continue }

            let key = "\(agentName)|\(host.processIdentifier)"
            guard seen.insert(key).inserted else { continue }
            sessions.append(AgentSession(agentName: agentName, kind: .cli, hostApp: host))
        }

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, let title = guiAgents[bundleID] else { continue }
            sessions.append(AgentSession(agentName: title, kind: .gui, hostApp: app))
        }

        if let preferred = preferredHostPID {
            let front = sessions.filter { $0.hostApp.processIdentifier == preferred }
            if !front.isEmpty {
                sessions = front + sessions.filter { $0.hostApp.processIdentifier != preferred }
            }
        }
        return sessions
        #endif
    }

    // MARK: 프로세스 조회

    private static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // 조회와 채우기 사이에 프로세스가 늘 수 있어 여유를 둔다.
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        procs.removeLast(procs.count - size / MemoryLayout<kinfo_proc>.stride)
        return procs
    }

    private static func commName(_ proc: kinfo_proc) -> String {
        var comm = proc.kp_proc.p_comm
        return withUnsafeBytes(of: &comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// node 등으로 실행된 스크립트에서 에이전트 이름을 찾는다: argv 앞쪽 인자의 파일 이름을 대조.
    private static func agentNameFromArguments(pid: pid_t) -> String? {
        for argument in arguments(pid: pid).prefix(4) where !argument.hasPrefix("-") {
            let base = (argument as NSString).lastPathComponent
            if let title = cliAgents[base] { return title }
            let stem = (base as NSString).deletingPathExtension
            if let title = cliAgents[stem] { return title }
        }
        return nil
    }

    /// KERN_PROCARGS2 버퍼: argc(4바이트) · 실행 경로 · NUL 패딩 · argv 문자열들.
    /// 실행 경로를 포함해 argc+1개까지 NUL 단위로 잘라 돌려준다.
    private static func arguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var strings: [String] = []
        var index = MemoryLayout<Int32>.size
        while index < size, strings.count < Int(argc) + 1 {
            while index < size, buffer[index] == 0 { index += 1 }
            guard index < size else { break }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
        }
        return strings
    }

    /// 부모 pid를 따라 올라가 처음 만나는 일반(GUI) 앱을 호스트로 삼는다.
    private static func hostApp(for pid: pid_t,
                                parents: [pid_t: pid_t],
                                apps: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<32 {
            if let app = apps[current] { return app }
            guard let parent = parents[current], parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }
}
