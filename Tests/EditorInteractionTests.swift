import XCTest
import AppKit

/// 편집기 마우스·키 조작 회귀 테스트. 실제 이벤트 좌표 변환을 위해 화면에 띄우지 않는 창에 올린다.
final class EditorInteractionTests: XCTestCase {
    private let side = 128
    private let rectangleAndText = Data("""
    {"version":1,"nextNumber":1,"annotations":[
     {"kind":"rectangle","start":[10,80],"end":[50,120],"color":[0,1,0,1],"width":3},
     {"kind":"text","text":"hello","start":[70,10],"end":[70,10],"color":[0,1,0,1],"width":3}]}
    """.utf8)

    @MainActor
    func testUndoWhileEditingTextDoesNotOverwriteAnotherAnnotation() throws {
        let (editor, window) = try makeEditor()
        defer { window.close() }
        XCTAssertTrue(editor.restoreAnnotations(from: rectangleAndText))
        click(editor, at: CGPoint(x: 30, y: 100))
        editor.delete(nil)                                    // 사각형 삭제 → 텍스트가 0번이 된다
        editor.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 75, y: 15), in: editor, clicks: 2))
        let field = try XCTUnwrap(editor.subviews.compactMap { $0 as? NSTextField }.first, "텍스트 편집이 열려야 한다")
        field.stringValue = "changed"

        editor.undo()
        XCTAssertTrue(editor.subviews.compactMap { $0 as? NSTextField }.isEmpty, "되돌리기 전에 인라인 편집을 끝내야 한다")
        editor.flushPendingAnnotationChanges()
        let records = try annotationRecords(editor)
        for record in records where (record["start"] as? [Double]) == [10, 80] {
            XCTAssertEqual(record["kind"] as? String, "rectangle", "다른 주석을 텍스트로 덮어쓰면 안 된다")
        }
        for record in records where record["kind"] as? String == "text" {
            XCTAssertEqual(record["start"] as? [Double], [70, 10])
        }
        editor.redo()
        XCTAssertTrue(try annotationRecords(editor).contains { $0["text"] as? String == "changed" }, "확정한 입력은 다시 실행으로 되살아나야 한다")
    }

    @MainActor
    func testCropToolWorksAfterUndoingEditMadeOutsideCropMode() throws {
        let (editor, window) = try makeEditor()
        defer { window.close() }
        editor.restoreAnnotations(from: rectangleAndText)
        click(editor, at: CGPoint(x: 30, y: 100))
        editor.delete(nil)                                    // 크롭 밖에서 기록된 되돌리기 스냅샷
        editor.tool = .crop
        editor.undo()
        editor.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 2, y: 2), in: editor))
        editor.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 20, y: 20), in: editor))
        editor.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 20, y: 20), in: editor))
        editor.commitCrop()
        let cropped = try XCTUnwrap(editor.baseCGImage())
        XCTAssertEqual(cropped.width, side - 20)
        XCTAssertEqual(cropped.height, side - 20)
    }

    @MainActor
    func testMovingMosaicResamplesPixelsAtNewLocation() throws {
        let (editor, window) = try makeEditor()
        defer { window.close() }
        let mosaic = Data("""
        {"version":1,"nextNumber":1,"annotations":[{"kind":"mosaic","start":[8,8],"end":[48,48],"color":[0,0,0,0],"width":0}]}
        """.utf8)
        editor.restoreAnnotations(from: mosaic)
        XCTAssertTrue(isRed(try pixel(editor, x: 28, y: 28)))

        // 드래그 이동: 빨강 영역 → 파랑 영역
        editor.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 28, y: 28), in: editor))
        editor.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 98, y: 28), in: editor))
        editor.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 98, y: 28), in: editor))
        XCTAssertTrue(isBlue(try pixel(editor, x: 98, y: 28)), "드래그로 옮긴 자리의 픽셀로 다시 샘플링해야 한다")

        // 방향키 이동: 처음 자리에서 다시 선택 후 ⇧→ 7번(70px)으로 파랑 영역
        editor.restoreAnnotations(from: mosaic)
        click(editor, at: CGPoint(x: 28, y: 28))
        for _ in 0..<7 {
            editor.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                                characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
                                                                isARepeat: false, keyCode: 124)))
        }
        XCTAssertTrue(isBlue(try pixel(editor, x: 98, y: 28)), "방향키로 옮긴 자리의 픽셀로 다시 샘플링해야 한다")
    }

    // MARK: 도우미
    @MainActor
    private func makeEditor() throws -> (EditorImageView, NSWindow) {
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: side / 2, y: 0, width: side / 2, height: side))
        let image = try XCTUnwrap(context.makeImage())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: side, height: side),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let editor = EditorImageView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        window.contentView = editor
        editor.image = NSImage(cgImage: image, size: NSSize(width: side, height: side))
        return (editor, window)
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in editor: EditorImageView, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: editor.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: 1)!
    }

    @MainActor
    private func click(_ editor: EditorImageView, at point: CGPoint) {
        editor.mouseDown(with: mouse(.leftMouseDown, at: point, in: editor))
        editor.mouseUp(with: mouse(.leftMouseUp, at: point, in: editor))
    }

    @MainActor
    private func annotationRecords(_ editor: EditorImageView) throws -> [[String: Any]] {
        guard let data = editor.annotationsData() else { return [] }
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(document["annotations"] as? [[String: Any]])
    }

    @MainActor
    private func pixel(_ editor: EditorImageView, x: Int, y: Int) throws -> NSColor {
        let rendered = try XCTUnwrap(editor.renderedCGImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: rendered).colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func isRed(_ color: NSColor) -> Bool { color.redComponent > 0.8 && color.blueComponent < 0.2 }
    private func isBlue(_ color: NSColor) -> Bool { color.blueComponent > 0.8 && color.redComponent < 0.2 }
}
