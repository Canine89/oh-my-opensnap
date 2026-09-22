import XCTest
import AppKit
import ImageIO

final class PNGEncodingTests: XCTestCase {
    func testRetinaScaleIsWrittenAsDPI() throws {
        let png = try XCTUnwrap(PNGEncoding.data(from: makeImage(width: 40, height: 20), scale: 2))
        XCTAssertEqual(try dpi(of: png), 144, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(NSImage(data: png)).size.width, 20, accuracy: 0.01, "논리 크기(point)로 붙여넣어져야 한다")
    }

    @MainActor
    func testEditorKeepsCaptureScaleThroughCropAndCopy() throws {
        let original = try XCTUnwrap(PNGEncoding.data(from: makeImage(width: 64, height: 64), scale: 2))
        let editor = EditorImageView(frame: .zero)
        editor.image = NSImage(data: original)
        XCTAssertEqual(editor.imageScale, 2)
        XCTAssertEqual(editor.baseCGImage()?.width, 64, "편집 좌표는 실제 픽셀 크기여야 한다")
        editor.tool = .crop
        editor.commitCrop()
        let rendered = try XCTUnwrap(editor.renderedPNGData())
        XCTAssertEqual(try dpi(of: rendered), 144, accuracy: 0.5)
    }

    @MainActor
    func testFlattenedDragCopyIncludesAnnotationsAndDPI() throws {
        let original = try XCTUnwrap(PNGEncoding.data(from: makeImage(width: 64, height: 64), scale: 2))
        let annotations = Data("""
        {"version":1,"nextNumber":1,"annotations":[{"kind":"rectangle","start":[4,4],"end":[60,60],"color":[1,0,0,1],"width":6}]}
        """.utf8)
        let flattened = try XCTUnwrap(EditorImageView.flattenedPNG(imageData: original, annotations: annotations))
        XCTAssertEqual(try dpi(of: flattened), 144, accuracy: 0.5)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: flattened))
        let edge = try XCTUnwrap(rep.colorAt(x: 4, y: 32)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(edge.redComponent, 0.8, "주석이 합성돼야 한다")
        XCTAssertNil(EditorImageView.flattenedPNG(imageData: original, annotations: Data("깨짐".utf8)),
                     "주석을 해석하지 못하면 원본을 내보내지 않는다")
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func dpi(of data: Data) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return try XCTUnwrap((properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue)
    }
}
