import AppKit

@MainActor
final class StorePreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard NSHomeDirectory().contains("/Containers/"), Bundle.main.bundleIdentifier == "com.goldenrabbit.omopensnap.storepreview" else { throw CocoaError(.executableNotLoadable) }
            Settings.shared.resetLibraryDirectory()
            let library = Settings.shared.libraryDirectory
            if FileManager.default.fileExists(atPath: library.path) { try FileManager.default.removeItem(at: library) }
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 760, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 1280, height: 760).fill()
            let title = loc("PYTHON PRACTICE", "파이썬 실습")
            (title as NSString).draw(at: NSPoint(x: 76, y: 640), withAttributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.labelColor
            ])
            let lines = ["def average(scores):", "    total = sum(scores)", "    return total / len(scores)", "", "scores = [85, 90, 95]", "print(average(scores))", "", "# 90.0"]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: 90, y: 554 - index * 50), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 28, weight: .medium),
                    .foregroundColor: index == 7 ? NSColor.secondaryLabelColor : NSColor(srgbRed: 0.16, green: 0.24, blue: 0.34, alpha: 1)
                ])
            }
            NSGraphicsContext.restoreGraphicsState()
            let cg = bitmap.cgImage!
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            let url = library.appendingPathComponent("python-practice-" + UUID().uuidString + ".png")
            let store = LibraryFileStore()
            try store.saveNew(png, at: url)
            let annotation: [String: Any] = ["version": 1, "nextNumber": 3, "annotations": [
                ["kind": "rectangle", "start": [72, 268], "end": [667, 315], "color": [0.88, 0.20, 0.18, 1], "width": 3],
                ["kind": "number", "number": 1, "start": [42, 290], "end": [42, 290], "color": [0.88, 0.20, 0.18, 1], "width": 3],
                ["kind": "number", "number": 2, "start": [42, 440], "end": [42, 440], "color": [0.88, 0.20, 0.18, 1], "width": 3],
                ["kind": "text", "text": loc("A clear explanation starts here.", "설명이 필요한 곳에 바로 주석을 남기세요."),
                 "start": [740, 285], "end": [740, 285], "color": [0.88, 0.20, 0.18, 1], "width": 2]
            ]]
            try store.saveAnnotations(JSONSerialization.data(withJSONObject: annotation), at: url)
            NSApp.appearance = NSAppearance(named: .aqua)
            LibraryWindowController.shared.showWindow(selecting: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }) else { return }
                window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print("PREVIEW_WINDOW: " + String(window.windowNumber))
                    fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { self.snapshot(window) }
                }
            }
        } catch { print("PREVIEW_FAILED: \(error)"); fflush(stdout); NSApp.terminate(nil) }
    }

    private func snapshot(_ window: NSWindow) {
        do {
            guard let view = window.contentView?.superview,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let outputDirectory = Settings.preferredLibraryDirectory.deletingLastPathComponent().appendingPathComponent("StorePreviewOutput")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let output = outputDirectory.appendingPathComponent("store-preview.png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: output)
            print("PREVIEW_PATH: " + output.path)
            fflush(stdout)
        } catch { print("PREVIEW_FAILED: \(error)"); fflush(stdout) }
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = StorePreviewDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
