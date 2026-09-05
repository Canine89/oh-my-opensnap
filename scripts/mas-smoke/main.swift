import AppKit

// 실제 앱과 같은 저장 구현을 Developer ID 서명 + App Sandbox로 실행한다.
// 운영 앱과 다른 번들 ID와 컨테이너를 사용하며 화면 녹화 권한은 요청하지 않는다.
final class SmokeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Smoke-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            guard NSHomeDirectory().contains("/Containers/") else { throw CocoaError(.executableNotLoadable) }
            let store = LibraryFileStore()
            let original = Data("샌드박스 원본".utf8)
            let item = root.appendingPathComponent("capture.png")
            try store.saveNew(original, at: item)
            try store.saveEdit(image: Data("편집 이미지".utf8), annotations: Data("주석".utf8), at: item)
            guard try store.load(at: item).annotations == Data("주석".utf8) else { throw CocoaError(.fileReadCorruptFile) }
            let exported = root.appendingPathComponent("export.mp4")
            try CoordinatedFileExporter.copy(from: item, to: exported)
            try CoordinatedFileExporter.write(original, to: exported)
            guard try Data(contentsOf: exported) == original else { throw CocoaError(.fileReadCorruptFile) }

            // 컨테이너 밖의 지정되지 않은 파일은 접근 권한이 없어야 한다.
            let forbidden = URL(fileURLWithPath: "/private/tmp/omos-denied-" + UUID().uuidString)
            var denied = false
            do { try original.write(to: forbidden) }
            catch { denied = true }
            guard denied else {
                try? FileManager.default.removeItem(at: forbidden)
                throw CocoaError(.executableNotLoadable)
            }

            let collection = root.appendingPathComponent("large-library", isDirectory: true)
            try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
            for index in 0..<10_000 {
                try FileManager.default.linkItem(at: item, to: collection.appendingPathComponent("capture-\(index).png"))
            }
            let started = Date()
            let items = try LibraryCatalog.load(directory: collection)
            guard items.count == 10_000 else { throw CocoaError(.fileReadCorruptFile) }
            let report: [String: Any] = ["sandbox": true, "containerStorage": "passed",
                                       "coordinatedExport": "passed", "unauthorizedExternalWrite": "denied",
                                       "catalogItems": items.count, "catalogSeconds": Date().timeIntervalSince(started)]
            print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
            fflush(stdout)
        } catch {
            print("SMOKE_FAILED: \(error)")
            fflush(stdout)
        }
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let delegate = SmokeDelegate()
application.delegate = delegate
application.setActivationPolicy(.prohibited)
application.run()
