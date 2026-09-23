import XCTest
import AppKit

/// 이미지 얹기: 크기 계산 · 저장/복원 · 쌓임 순서 · 모자이크 · 되돌리기 · 크롭 회귀 테스트.
final class ImageInsertionTests: XCTestCase {
    private let side = 128
    private let green: (CGFloat, CGFloat, CGFloat) = (0, 1, 0)

    // MARK: 크기·위치 (순수 함수)
    func testInsertionSizeConvertsDensityAndCapsAtSixtyPercent() {
        let canvas = CGSize(width: 1000, height: 1000)
        // Retina(2x) 원본 → 1x 캡처: 논리 크기 그대로 = 픽셀 절반
        XCTAssertEqual(ImageInsertionLayout.size(pixelSize: CGSize(width: 400, height: 200), sourceScale: 2,
                                                 targetScale: 1, canvas: canvas), CGSize(width: 200, height: 100))
        // 1x 원본 → 2x 캡처: 픽셀 두 배
        XCTAssertEqual(ImageInsertionLayout.size(pixelSize: CGSize(width: 100, height: 50), sourceScale: 1,
                                                 targetScale: 2, canvas: canvas), CGSize(width: 200, height: 100))
        // 60% 상한: 가로가 넘치면 가로 기준, 세로가 넘치면 세로 기준으로 비율 유지
        XCTAssertEqual(ImageInsertionLayout.size(pixelSize: CGSize(width: 2000, height: 200), sourceScale: 1,
                                                 targetScale: 1, canvas: CGSize(width: 500, height: 500)),
                       CGSize(width: 300, height: 30))
        XCTAssertEqual(ImageInsertionLayout.size(pixelSize: CGSize(width: 100, height: 1000), sourceScale: 1,
                                                 targetScale: 1, canvas: CGSize(width: 1000, height: 500)),
                       CGSize(width: 30, height: 300))
        // 가장자리 드롭도 캔버스 안으로 민다
        let size = CGSize(width: 100, height: 100)
        XCTAssertEqual(ImageInsertionLayout.rect(size: size, centeredAt: CGPoint(x: 10, y: 10), canvas: CGSize(width: 500, height: 500)),
                       CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(ImageInsertionLayout.rect(size: size, centeredAt: CGPoint(x: 495, y: 250), canvas: CGSize(width: 500, height: 500)),
                       CGRect(x: 400, y: 200, width: 100, height: 100))
        // 비율 유지 크기 조절: 큰 배율을 따르고 캔버스 밖으로 나가지 않는다
        let r = CGRect(x: 10, y: 10, width: 40, height: 20)
        let canvasRect = CGRect(x: 0, y: 0, width: 128, height: 128)
        XCTAssertEqual(ImageInsertionLayout.aspectResizedRect(r, fixed: r.origin, toward: CGPoint(x: 90, y: 20), within: canvasRect),
                       CGRect(x: 10, y: 10, width: 80, height: 40))
        XCTAssertEqual(ImageInsertionLayout.aspectResizedRect(r, fixed: r.origin, toward: CGPoint(x: 500, y: 500), within: canvasRect),
                       CGRect(x: 10, y: 10, width: 118, height: 59))
    }

    @MainActor
    func testDecodedRetinaImageKeepsLogicalSizeOnInsert() throws {
        let png = try XCTUnwrap(PNGEncoding.data(from: solid(width: 40, height: 20, green), scale: 2))
        let decoded = try XCTUnwrap(InsertableImage.decode(data: png))
        XCTAssertEqual(decoded.scale, 2)
        XCTAssertEqual(decoded.cgImage.width, 40)
        let editor = EditorImageView(frame: .zero)
        editor.image = NSImage(cgImage: try solid(width: side, height: side, (1, 1, 1)), size: NSSize(width: side, height: side))
        XCTAssertTrue(editor.insertImage(decoded, centeredAt: CGPoint(x: 64, y: 64)))
        let record = try XCTUnwrap(records(editor).first)
        XCTAssertEqual(record["start"] as? [Double], [54, 59], "2x 원본은 1x 캡처에서 논리 크기(20×10)로 들어가야 한다")
        XCTAssertEqual(record["end"] as? [Double], [74, 69])
    }

    // MARK: 저장/복원
    @MainActor
    func testImageObjectAndAssetRoundTripAndCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.png")
        let base = try solid(width: side, height: side, (1, 1, 1))
        let store = LibraryFileStore()
        try store.saveNew(try XCTUnwrap(PNGEncoding.data(from: base, scale: 1)), at: url)

        let editor = EditorImageView(frame: .zero)
        editor.image = NSImage(cgImage: base, size: NSSize(width: side, height: side))
        XCTAssertTrue(editor.insertImage(InsertableImage(cgImage: try solid(width: 20, height: 20, green), scale: 1),
                                         centeredAt: CGPoint(x: 64, y: 64)))
        let assets = editor.annotationAssets()
        let id = try XCTUnwrap(assets.keys.first)
        try store.saveAnnotations(editor.annotationsData(), assets: assets, at: url)
        let assetURL = try XCTUnwrap(LibraryFileStore.assetURL(id: id, for: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
        XCTAssertEqual(assetURL.deletingLastPathComponent().lastPathComponent, "capture.png.assets")

        let loaded = try store.load(at: url)
        XCTAssertEqual(loaded.assets.count, 1)
        let reopened = EditorImageView(frame: .zero)
        reopened.image = NSImage(data: loaded.image)
        XCTAssertTrue(reopened.restoreAnnotations(from: try XCTUnwrap(loaded.annotations), assets: loaded.assets))
        XCTAssertEqual(reopened.missingImageAssetCount, 0)
        let record = try XCTUnwrap(records(reopened).first)
        XCTAssertEqual(record["kind"] as? String, "image")
        XCTAssertEqual(record["asset"] as? String, id)
        XCTAssertEqual(record["start"] as? [Double], [54, 54])
        XCTAssertTrue(isGreen(try pixel(reopened.renderedCGImage(), 64, 64)))
        let flattened = try XCTUnwrap(EditorImageView.flattenedPNG(imageData: loaded.image, annotations: try XCTUnwrap(loaded.annotations),
                                                                   assets: loaded.assets))
        XCTAssertTrue(isGreen(try pixel(NSBitmapImageRep(data: flattened)?.cgImage, 64, 64)), "드래그 합성본에도 얹은 이미지가 들어가야 한다")
        XCTAssertEqual(try pixel(store.load(at: url).image.cgImage, 64, 64).redComponent, 1, accuracy: 0.01,
                       "원본 픽셀(흰 바탕)은 건드리지 않는다")

        // 오브제를 지우면 저장 때 자산도 정리되고, 되돌리면 메모리의 원본으로 다시 쓴다.
        editor.delete(nil)
        try store.saveAnnotations(editor.annotationsData(), assets: editor.annotationAssets(), at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path))
        editor.undo()
        try store.saveAnnotations(editor.annotationsData(), assets: editor.annotationAssets(), at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path), "되돌린 오브제의 자산은 다시 저장돼야 한다")

        // 라이브러리에서 캡처를 지워도 주석 JSON과 자산은 보존한다 — Finder 복원 시 얹은 이미지까지 돌아오게.
        let trashed = directory.appendingPathComponent("trashed.png")
        let trashing = LibraryFileStore(moveToTrash: { try FileManager.default.moveItem(at: $0, to: trashed) })
        try trashing.trash(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: LibraryFileStore.annotationsURL(for: url).path))
    }

    @MainActor
    func testMissingOrInvalidAssetIsSkippedWithoutBlockingLoad() throws {
        let json = Data("""
        {"version":1,"nextNumber":1,"annotations":[
         {"kind":"rectangle","start":[10,10],"end":[50,50],"color":[1,0,0,1],"width":3},
         {"kind":"image","asset":"\(UUID().uuidString)","start":[20,20],"end":[60,60],"color":[0,0,0,0],"width":0},
         {"kind":"image","asset":"../../escape","start":[20,20],"end":[60,60],"color":[0,0,0,0],"width":0},
         {"kind":"image","start":[20,20],"end":[60,60],"color":[0,0,0,0],"width":0}]}
        """.utf8)
        let editor = EditorImageView(frame: .zero)
        editor.image = NSImage(cgImage: try solid(width: side, height: side, (1, 1, 1)), size: NSSize(width: side, height: side))
        XCTAssertTrue(editor.restoreAnnotations(from: json, assets: ["../../escape": Data("x".utf8)]))
        XCTAssertEqual(editor.missingImageAssetCount, 3)
        XCTAssertEqual(try records(editor).map { $0["kind"] as? String }, ["rectangle"], "나머지 주석은 그대로 열린다")
        let base = try XCTUnwrap(PNGEncoding.data(from: solid(width: side, height: side, (1, 1, 1)), scale: 1))
        XCTAssertNil(EditorImageView.flattenedPNG(imageData: base, annotations: json),
                     "가리개로 얹은 이미지가 빠진 합성본은 내보내지 않는다")
    }

    // MARK: 쌓임 순서 · 모자이크
    @MainActor
    func testFlattenDrawsInsertedImageBelowAnnotations() throws {
        let id = UUID().uuidString
        // 배열에선 사각형이 먼저여도 얹은 이미지는 항상 그 아래에 그려진다.
        let json = Data("""
        {"version":1,"nextNumber":1,"annotations":[
         {"kind":"rectangle","start":[40,40],"end":[88,88],"color":[1,0,0,1],"width":6},
         {"kind":"image","asset":"\(id)","start":[30,30],"end":[98,98],"color":[0,0,0,0],"width":0}]}
        """.utf8)
        let asset = try XCTUnwrap(PNGEncoding.data(from: solid(width: 68, height: 68, green), scale: 1))
        let base = try XCTUnwrap(PNGEncoding.data(from: solid(width: side, height: side, (1, 1, 1)), scale: 1))
        let flattened = try XCTUnwrap(EditorImageView.flattenedPNG(imageData: base, annotations: json, assets: [id: asset]))
        let image = NSBitmapImageRep(data: flattened)?.cgImage
        XCTAssertTrue(isRed(try pixel(image, 40, 64)), "사각형 선이 얹은 이미지 위에 있어야 한다")
        XCTAssertTrue(isGreen(try pixel(image, 64, 64)), "사각형 안쪽엔 얹은 이미지가 보여야 한다")
        XCTAssertTrue(isGreen(try pixel(image, 33, 33)))
        XCTAssertEqual(try pixel(image, 10, 10).blueComponent, 1, accuracy: 0.01, "바탕은 그대로")
    }

    @MainActor
    func testMosaicPixelatesInsertedImagePixels() throws {
        let id = UUID().uuidString
        let stripes = try XCTUnwrap(PNGEncoding.data(from: stripeImage(width: 64, height: 64), scale: 1))
        let base = try XCTUnwrap(PNGEncoding.data(from: solid(width: side, height: side, (1, 1, 1)), scale: 1))
        // 모자이크가 배열에서 먼저여도 얹은 이미지 위를 가린다.
        let json = Data("""
        {"version":1,"nextNumber":1,"annotations":[
         {"kind":"mosaic","start":[32,32],"end":[96,96],"color":[0,0,0,0],"width":0},
         {"kind":"image","asset":"\(id)","start":[32,32],"end":[96,96],"color":[0,0,0,0],"width":0}]}
        """.utf8)
        let flattened = try XCTUnwrap(EditorImageView.flattenedPNG(imageData: base, annotations: json, assets: [id: stripes]))
        try assertPixelated(NSBitmapImageRep(data: flattened)?.cgImage, in: CGRect(x: 32, y: 32, width: 64, height: 64))

        // 편집기에서: 얹은 이미지 위에 ⌥드래그로 모자이크를 그린다(그냥 드래그는 이미지를 옮긴다).
        let (editor, window) = try makeEditor()
        defer { window.close() }
        XCTAssertTrue(editor.insertImage(InsertableImage(cgImage: try stripeImage(width: 64, height: 64), scale: 1),
                                         centeredAt: CGPoint(x: 64, y: 64)))
        editor.tool = .mosaic
        editor.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 32, y: 32), in: editor, flags: .option))
        editor.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 96, y: 96), in: editor, flags: .option))
        editor.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 96, y: 96), in: editor, flags: .option))
        XCTAssertEqual(try records(editor).map { $0["kind"] as? String }, ["image", "mosaic"])
        try assertPixelated(editor.renderedCGImage(), in: CGRect(x: 32, y: 32, width: 64, height: 64))
    }

    // MARK: 조작 · 되돌리기
    @MainActor
    func testUndoRedoInsertMoveResizeAndDelete() throws {
        let (editor, window) = try makeEditor()
        defer { window.close() }
        XCTAssertTrue(editor.insertImage(InsertableImage(cgImage: try solid(width: 20, height: 20, green), scale: 1),
                                         centeredAt: CGPoint(x: 40, y: 40)))
        XCTAssertEqual(try start(editor), [30, 30])
        editor.undo()
        XCTAssertNil(editor.annotationsData())
        editor.redo()
        XCTAssertEqual(try start(editor), [30, 30])

        // 사각형 도구가 켜져 있어도 오브제 위 드래그는 이동이다(새 사각형을 그리지 않는다).
        editor.tool = .rectangle
        drag(editor, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 80, y: 70))
        XCTAssertEqual(try records(editor).count, 1)
        XCTAssertEqual(try start(editor), [70, 60])
        XCTAssertTrue(isGreen(try pixel(editor.renderedCGImage(), 80, 70)))
        editor.undo()
        XCTAssertEqual(try start(editor), [30, 30])
        editor.redo()
        XCTAssertEqual(try start(editor), [70, 60])

        // 모서리 핸들: 비율 유지(1:1 원본 → 정사각형 유지). 되돌리기/다시 실행은 선택을 풀므로 먼저 선택한다.
        click(editor, at: CGPoint(x: 80, y: 70))
        drag(editor, from: CGPoint(x: 90, y: 80), to: CGPoint(x: 100, y: 85))
        let resized = try XCTUnwrap(records(editor).first)
        XCTAssertEqual(resized["start"] as? [Double], [70, 60])
        XCTAssertEqual(resized["end"] as? [Double], [100, 90])
        editor.undo()
        XCTAssertEqual(try XCTUnwrap(records(editor).first)["end"] as? [Double], [90, 80])

        // 방향키 ⇧→ 10px, ⌫ 삭제, ⌘Z 복원
        click(editor, at: CGPoint(x: 80, y: 70))
        editor.keyDown(with: try key(124, window: window, flags: .shift))
        XCTAssertEqual(try start(editor), [80, 60])
        editor.keyDown(with: try key(51, window: window))
        XCTAssertNil(editor.annotationsData())
        editor.undo()
        XCTAssertEqual(try start(editor), [80, 60])
        XCTAssertTrue(isGreen(try pixel(editor.renderedCGImage(), 90, 70)), "되돌린 뒤에도 자산이 살아 있어야 한다")
    }

    @MainActor
    func testCropTranslatesInsertedImage() throws {
        let (editor, window) = try makeEditor()
        defer { window.close() }
        XCTAssertTrue(editor.insertImage(InsertableImage(cgImage: try solid(width: 20, height: 20, green), scale: 1),
                                         centeredAt: CGPoint(x: 64, y: 64)))
        editor.tool = .crop
        drag(editor, from: CGPoint(x: 2, y: 2), to: CGPoint(x: 20, y: 20))
        editor.commitCrop()
        let cropped = try XCTUnwrap(editor.baseCGImage())
        XCTAssertEqual(cropped.width, side - 20)
        // 다른 주석처럼 크롭 결과에 합성되며, 크롭 원점만큼 옮겨진다(54 → 34).
        XCTAssertTrue(isGreen(try pixel(cropped, 44, 44)))
        XCTAssertTrue(isGreen(try pixel(cropped, 34, 34)))
        XCTAssertFalse(isGreen(try pixel(cropped, 32, 32)))
        XCTAssertNil(editor.annotationsData())
        editor.undo()
        XCTAssertEqual(try start(editor), [54, 54], "크롭을 되돌리면 오브제로 돌아온다")
    }

    // MARK: 도우미
    @MainActor
    private func makeEditor() throws -> (EditorImageView, NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: side, height: side),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let editor = EditorImageView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        window.contentView = editor
        editor.image = NSImage(cgImage: try solid(width: side, height: side, (1, 1, 1)), size: NSSize(width: side, height: side))
        return (editor, window)
    }

    private func solid(width: Int, height: Int, _ rgb: (CGFloat, CGFloat, CGFloat)) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// 1px 빨강/파랑 세로 줄무늬 — 모자이크로 평균 내면 보라색이 된다.
    private func stripeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<width {
            context.setFillColor(x.isMultiple(of: 2) ? CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
                                                     : CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// 영역 안의 어떤 픽셀도 원래 줄무늬(순수 빨강/파랑)로 남아 있지 않고, 흰 바탕도 아니다.
    private func assertPixelated(_ image: CGImage?, in rect: CGRect, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(image, file: file, line: line)
        let rep = NSBitmapImageRep(cgImage: image)
        for y in stride(from: Int(rect.minY) + 1, to: Int(rect.maxY) - 1, by: 3) {
            for x in stride(from: Int(rect.minX) + 1, to: Int(rect.maxX) - 1, by: 1) {
                let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), file: file, line: line)
                XCTAssertTrue(c.redComponent > 0.2 && c.redComponent < 0.8 && c.blueComponent > 0.2 && c.blueComponent < 0.8
                              && c.greenComponent < 0.2,
                              "(\(x),\(y)) 얹은 이미지 픽셀이 뭉개지지 않았다: \(c)", file: file, line: line)
            }
        }
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in editor: EditorImageView,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: editor.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                           windowNumber: editor.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }

    @MainActor
    private func click(_ editor: EditorImageView, at point: CGPoint) {
        editor.mouseDown(with: mouse(.leftMouseDown, at: point, in: editor))
        editor.mouseUp(with: mouse(.leftMouseUp, at: point, in: editor))
    }

    @MainActor
    private func drag(_ editor: EditorImageView, from: CGPoint, to: CGPoint) {
        editor.mouseDown(with: mouse(.leftMouseDown, at: from, in: editor))
        editor.mouseDragged(with: mouse(.leftMouseDragged, at: to, in: editor))
        editor.mouseUp(with: mouse(.leftMouseUp, at: to, in: editor))
    }

    private func key(_ code: UInt16, window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: "",
                                       charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    @MainActor
    private func records(_ editor: EditorImageView) throws -> [[String: Any]] {
        guard let data = editor.annotationsData() else { return [] }
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(document["annotations"] as? [[String: Any]])
    }

    @MainActor
    private func start(_ editor: EditorImageView) throws -> [Double]? {
        try XCTUnwrap(records(editor).first { $0["kind"] as? String == "image" })["start"] as? [Double]
    }

    private func pixel(_ image: CGImage?, _ x: Int, _ y: Int) throws -> NSColor {
        try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(image)).colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func isGreen(_ c: NSColor) -> Bool { c.greenComponent > 0.8 && c.redComponent < 0.2 && c.blueComponent < 0.2 }
    private func isRed(_ c: NSColor) -> Bool { c.redComponent > 0.8 && c.greenComponent < 0.2 }
}

private extension Data {
    var cgImage: CGImage? { NSBitmapImageRep(data: self)?.cgImage }
}
