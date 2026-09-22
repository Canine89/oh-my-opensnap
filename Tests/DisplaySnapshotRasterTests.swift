import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class DisplaySnapshotRasterTests: XCTestCase {
    func testRasterPreservesOrientationColorsAndLoupeAtEdges() throws {
        let width = 16, height = 12
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                pixels += [UInt8(x * 10), UInt8(y * 15), UInt8((x + y) * 8), 255]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height,
                                        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        // 실제 캡처처럼 나중에 디코딩될 수 있는 이미지를 입력으로 사용한다.
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded, nil))
        let lazy = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCache: false] as CFDictionary))
        let raster = try XCTUnwrap(DisplaySnapshot.rasterizedImage(lazy))
        XCTAssertEqual(raster.width, width)
        XCTAssertEqual(raster.height, height)
        XCTAssertEqual(raster.bitsPerPixel, 32)
        XCTAssertEqual(raster.bitsPerComponent, 8)

        for (x, y) in [(0, 0), (15, 0), (0, 11), (15, 11), (7, 6)] {
            let expected = try XCTUnwrap(PixelSampling.sample(image, centerX: x, centerY: y, radius: 2))
            let actual = try XCTUnwrap(PixelSampling.sample(raster, centerX: x, centerY: y, radius: 2))
            XCTAssertEqual(actual.centerColor.r, expected.centerColor.r)
            XCTAssertEqual(actual.centerColor.g, expected.centerColor.g)
            XCTAssertEqual(actual.centerColor.b, expected.centerColor.b)
            XCTAssertEqual(actual.image.dataProvider?.data as Data?, expected.image.dataProvider?.data as Data?)
        }

        let crop = try XCTUnwrap(DisplaySnapshot(image: raster, scale: 2)
            .crop(viewRect: CGRect(x: 1, y: 1, width: 4, height: 3)))
        XCTAssertEqual(crop.width, 8)
        XCTAssertEqual(crop.height, 6)
        let corner = try XCTUnwrap(PixelSampling.sample(crop, centerX: 0, centerY: 0, radius: 0))
        XCTAssertEqual(corner.centerColor.r, 20)
        XCTAssertEqual(corner.centerColor.g, 30)
        XCTAssertEqual(corner.centerColor.b, 32)
    }

    func testPreparedImageFallsBackToOriginalWhenRasterFails() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 6, height: 4,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        // 펼치기에 실패해도 유효한 캡처를 버리지 않는다(정지 화면·확정 캡처가 사라지면 안 된다).
        XCTAssertTrue(DisplaySnapshot.preparedImage(image, rasterize: { _ in nil }) === image)
        let prepared = DisplaySnapshot.preparedImage(image)
        XCTAssertFalse(prepared === image, "성공하면 펼친 비트맵을 쓴다")
        XCTAssertEqual(prepared.width, 6)
        XCTAssertEqual(prepared.height, 4)
    }
}
