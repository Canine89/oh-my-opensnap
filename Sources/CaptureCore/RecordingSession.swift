import Foundation

@MainActor
protocol Recording: AnyObject {
    func start() async throws
    func stop() async throws -> URL
    func setPaused(_ paused: Bool)
}

/// 시작 중 종료, 중복 중지, 저장 중 재시작을 한 곳에서 제어한다.
@MainActor
final class RecordingSession {
    enum State { case idle, starting, recording, stopping }
    private(set) var state: State = .idle
    private var identity: UUID?
    private var recorder: Recording?
    private var startTask: Task<Void, Error>?
    private var stopTask: Task<URL, Error>?
    var isBusy: Bool { state != .idle }

    func start(_ recording: Recording) async throws {
        guard !isBusy else { throw RecordingError.busy }
        let id = UUID()
        identity = id
        recorder = recording
        state = .starting
        let task = Task { try await recording.start() }
        startTask = task
        do {
            try await task.value
            if identity == id, state == .starting { state = .recording }
        } catch {
            if state != .stopping { reset(identity: id) }
            throw error
        }
    }

    func stop() async throws -> URL? {
        if let stopTask { return try await stopTask.value }
        guard let recorder, let id = identity else { return nil }
        let start = startTask
        state = .stopping
        let task = Task {
            try await start?.value
            return try await recorder.stop()
        }
        stopTask = task
        defer { reset(identity: id) }
        return try await task.value
    }

    func setPaused(_ paused: Bool) {
        guard state == .recording else { return }
        recorder?.setPaused(paused)
    }

    func isCurrent(_ recording: Recording) -> Bool { recorder === recording }

    private func reset(identity expected: UUID) {
        guard identity == expected else { return }
        identity = nil
        recorder = nil
        startTask = nil
        stopTask = nil
        state = .idle
    }
}

enum RecordingError: LocalizedError {
    case busy, noFrames, writeFailed
    var errorDescription: String? {
        switch self {
        case .busy: return loc("A recording is already starting or being saved.", "녹화를 시작하거나 저장하는 중입니다.")
        case .noFrames: return loc("No video frames were captured.", "저장할 영상 프레임이 없습니다.")
        case .writeFailed: return loc("The recording could not be saved.", "녹화 파일을 저장하지 못했습니다.")
        }
    }
}
