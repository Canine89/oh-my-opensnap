import XCTest
import AppKit

final class EditorPersistenceTests: XCTestCase {
    @MainActor
    func testCropUndoReloadDoesNotBakeAnnotationsIntoOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
                                              bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let original = try XCTUnwrap(context.makeImage())
        let store = LibraryFileStore()
        try store.saveNew(png(original), at: url)
        let editor = EditorImageView(frame: CGRect(x: 0, y: 0, width: 128, height: 128))
        editor.image = NSImage(cgImage: original, size: NSSize(width: 128, height: 128))
        let annotation = Data("""
        {"version":1,"nextNumber":1,"annotations":[{"kind":"rectangle","start":[20,20],"end":[100,100],"color":[1,0,0,1],"width":4}]}
        """.utf8)
        editor.restoreAnnotations(from: annotation)
        var saveError: Error?
        editor.onEditCommitted = {
            do {
                try store.saveEdit(image: self.png(XCTUnwrap(editor.baseCGImage())),
                                   annotations: editor.annotationsData(), at: url)
            } catch { saveError = error }
        }
        editor.tool = .crop
        editor.commitCrop()
        XCTAssertNil(editor.annotationsData())
        editor.undo()
        XCTAssertNil(saveError)
        XCTAssertNotNil(editor.annotationsData())
        let loaded = try store.load(at: url)
        let persisted = try XCTUnwrap(NSImage(data: loaded.image)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(redPixels(persisted), 0, "되돌린 원본에는 주석 픽셀이 없어야 한다")
        let reopened = EditorImageView(frame: editor.frame)
        reopened.image = NSImage(cgImage: persisted, size: editor.frame.size)
        reopened.restoreAnnotations(from: try XCTUnwrap(loaded.annotations))
        XCTAssertGreaterThan(redPixels(try XCTUnwrap(reopened.renderedCGImage())), 0)
        reopened.restoreAnnotations(from: Data("{\"version\":1,\"nextNumber\":1,\"annotations\":[]}".utf8))
        XCTAssertEqual(redPixels(try XCTUnwrap(reopened.renderedCGImage())), 0, "주석을 지우면 잔상이 없어야 한다")
        editor.redo()
        XCTAssertNil(saveError)
        XCTAssertNil(try store.load(at: url).annotations)
    }

    func testHistoryDropsRedoAfterNewEditAndHonorsLimit() {
        var history = EditHistory<Int>(limit: 2)
        history.record(1)
        history.record(2)
        history.record(3)
        XCTAssertEqual(history.undo(current: 4), 3)
        XCTAssertEqual(history.undo(current: 3), 2)
        XCTAssertNil(history.undo(current: 2))
        XCTAssertEqual(history.redo(current: 2), 3)
        history.record(3)
        XCTAssertFalse(history.canRedo)
    }

    private func png(_ image: CGImage) throws -> Data {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private func redPixels(_ image: CGImage) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var result = 0
        for x in 0..<image.width { for y in 0..<image.height {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               color.redComponent > 0.8, color.greenComponent < 0.2 { result += 1 }
        }}
        return result
    }
}
