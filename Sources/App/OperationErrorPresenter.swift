import AppKit

@MainActor
enum OperationErrorPresenter {
    static func show(_ error: Error, action: String) {
        NSLog("%@: %@", action, error.localizedDescription)
        let alert = NSAlert(error: error)
        alert.messageText = action
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
