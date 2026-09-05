import AppKit

/// 저장 실패 해결을 한 번에 한 창으로 안내한다. 종료할 때도 같은 선택지를 사용한다.
@MainActor
final class SaveRecoveryController {
    static let shared = SaveRecoveryController()
    private var isPresenting = false
    private init() {}

    func show(_ error: Error) {
        Task { _ = await resolve(error, terminating: false) }
    }

    func resolve(_ initialError: Error, terminating: Bool) async -> Bool {
        guard !isPresenting else { return false }
        isPresenting = true
        defer { isPresenting = false }
        LibraryWindowController.shared.flushPendingEdits()
        var error = initialError
        while true {
            let count = await CaptureLibrary.shared.pendingWriteCount()
            guard count > 0 else { return true }
            switch chooseAction(error: error, count: count, terminating: terminating) {
            case .alertFirstButtonReturn:
                do { try await CaptureLibrary.shared.flush(); return true }
                catch let retryError { error = retryError }
            case .alertSecondButtonReturn:
                guard let directory = chooseRecoveryFolder() else { return false }
                let report = await CaptureLibrary.shared.recoverPendingWrites(to: directory)
                if !report.files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(Array(report.files.values)) }
                if let recoveryError = report.failures.values.first { error = recoveryError }
                else { return true }
            case .alertThirdButtonReturn:
                return false
            default:
                guard confirmDiscard(count: count) else { continue }
                await CaptureLibrary.shared.discardPendingWrites()
                if !terminating { LibraryWindowController.shared.discardUnsavedPreview() }
                return true
            }
        }
    }

    private func chooseAction(error: Error, count: Int, terminating: Bool) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = loc("\(count) capture(s) could not be saved", "캡처 \(count)개의 변경 내용을 저장하지 못했습니다")
        alert.informativeText = loc("Your unsaved captures are still in memory. Reconnect the drive or choose another folder to save recoverable copies, including annotations.",
                                    "저장하지 못한 캡처를 메모리에 보관하고 있습니다. 저장 장치를 다시 연결하거나 다른 폴더에 주석을 포함한 복구본을 저장할 수 있습니다.")
            + "\n\n" + error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: loc("Retry", "다시 시도"))
        alert.addButton(withTitle: loc("Save to Another Folder…", "다른 폴더에 저장…"))
        alert.addButton(withTitle: loc("Keep Editing", "계속 편집"))
        alert.addButton(withTitle: terminating ? loc("Discard and Quit…", "변경 내용을 버리고 종료…") : loc("Discard Changes…", "변경 내용 버리기…"))
        alert.buttons[2].keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private func chooseRecoveryFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = loc("Choose a folder for the recovered captures and their editable annotations.", "캡처와 편집 가능한 주석의 복구본을 저장할 폴더를 선택하세요.")
        panel.prompt = loc("Save Copies Here", "여기에 복구본 저장")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func confirmDiscard(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = loc("Discard unsaved changes?", "저장하지 않은 변경 내용을 버릴까요?")
        alert.informativeText = loc("Unsaved changes to \(count) capture(s) will be lost. Files already on disk will be kept.",
                                    "캡처 \(count)개의 저장하지 않은 변경 내용이 사라집니다. 디스크에 이미 저장된 파일은 유지됩니다.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: loc("Keep Changes", "변경 내용 유지"))
        alert.addButton(withTitle: loc("Discard", "변경 내용 버리기"))
        return alert.runModal() == .alertSecondButtonReturn
    }
}
