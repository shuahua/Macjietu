import AppKit
import XCTest
@testable import 截图Free

final class CaptureGeometryTests: XCTestCase {
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private var red: CGColor { CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])! }
    private var blue: CGColor { CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0, 0, 1, 1])! }

    func testQuartzConversionForLeftAboveAndBelowDisplays() {
        XCTAssertEqual(CaptureGeometry.quartzRect(CGRect(x: -1200, y: 100, width: 400, height: 300), primaryFrame: primary),
                       CGRect(x: -1200, y: 500, width: 400, height: 300))
        XCTAssertEqual(CaptureGeometry.quartzRect(CGRect(x: 50, y: 1000, width: 400, height: 300), primaryFrame: primary),
                       CGRect(x: 50, y: -400, width: 400, height: 300))
        XCTAssertEqual(CaptureGeometry.quartzPoint(CGPoint(x: -200, y: -100), primaryFrame: primary),
                       CGPoint(x: -200, y: 1000))
    }

    func testPixelCropUsesActualBitmapScaleAndTopOrigin() {
        let frame = CGRect(x: -100, y: 900, width: 100, height: 80)
        let rect = CGRect(x: -90.5, y: 950, width: 20, height: 10)
        XCTAssertEqual(CaptureGeometry.pixelRect(rect, in: frame, pixels: CGSize(width: 300, height: 240)),
                       CGRect(x: 28.5, y: 60, width: 60, height: 30))
    }

    private func bitmap(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes
    }

    func testMixedDPICrossScreenCaptureKeepsBothDisplaysAndRetinaPixels() throws {
        let red = try bitmap(width: 100, height: 100, color: self.red)
        let blue = try bitmap(width: 200, height: 200, color: self.blue)
        let result = try ScreenCaptureService.compose(rect: CGRect(x: -50, y: 0, width: 100, height: 100), tiles: [
            .init(frame: CGRect(x: -100, y: 0, width: 100, height: 100), image: red),
            .init(frame: CGRect(x: 0, y: 0, width: 100, height: 100), image: blue)
        ])
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 200)
        XCTAssertEqual(try pixel(result, x: 25, y: 50), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(result, x: 175, y: 50), [0, 0, 255, 255])
    }

    func testVerticalLayoutAndDesktopGapRemainCorrect() throws {
        let red = try bitmap(width: 20, height: 20, color: self.red)
        let blue = try bitmap(width: 20, height: 20, color: self.blue)
        let result = try ScreenCaptureService.compose(rect: CGRect(x: 0, y: -10, width: 10, height: 30), tiles: [
            .init(frame: CGRect(x: 0, y: -10, width: 10, height: 10), image: blue),
            .init(frame: CGRect(x: 0, y: 10, width: 10, height: 10), image: red)
        ])
        XCTAssertEqual(try pixel(result, x: 5, y: 5), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(result, x: 5, y: 30), [0, 0, 0, 0])
        XCTAssertEqual(try pixel(result, x: 5, y: 55), [0, 0, 255, 255])
    }

    func testSingleRetinaCropAndPNGPreservePixels() throws {
        let image = try bitmap(width: 200, height: 200, color: CGColor(gray: 0.5, alpha: 1))
        let result = try ScreenCaptureService.compose(rect: CGRect(x: -90, y: 20, width: 30, height: 40), tiles: [
            .init(frame: CGRect(x: -100, y: 0, width: 100, height: 100), image: image)
        ])
        XCTAssertEqual(result.width, 60)
        XCTAssertEqual(result.height, 80)
        let png = try ImageEncoding.pngData(from: NSImage(cgImage: result, size: CGSize(width: 30, height: 40)))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, 60)
        XCTAssertEqual(decoded.pixelsHigh, 80)
    }

    func testSingleDisplayCropSelectsTopRatherThanBottom() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(blue)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        context.setFillColor(red)
        context.fill(CGRect(x: 0, y: 20, width: 40, height: 20))
        let result = try ScreenCaptureService.compose(rect: CGRect(x: -20, y: 910, width: 20, height: 10), tiles: [
            .init(frame: CGRect(x: -20, y: 900, width: 20, height: 20), image: try XCTUnwrap(context.makeImage()))
        ])
        XCTAssertEqual(result.height, 20)
        XCTAssertEqual(try pixel(result, x: 5, y: 5), [255, 0, 0, 255])
    }

    func testFractionalNegativeSelectionDoesNotTruncateTowardZero() throws {
        let image = try bitmap(width: 200, height: 200, color: CGColor(gray: 1, alpha: 1))
        let result = try ScreenCaptureService.compose(rect: CGRect(x: -99.75, y: 0.25, width: 10.25, height: 10.25), tiles: [
            .init(frame: CGRect(x: -100, y: 0, width: 100, height: 100), image: image)
        ])
        XCTAssertEqual(result.width, 21)
        XCTAssertEqual(result.height, 21)
    }

    func testInvalidAndOffscreenRegionsFail() throws {
        XCTAssertFalse(CaptureGeometry.isValid(CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1)))
        XCTAssertThrowsError(try ScreenCaptureService.compose(rect: .zero, tiles: []))
        let image = try bitmap(width: 20, height: 20, color: CGColor(gray: 1, alpha: 1))
        XCTAssertThrowsError(try ScreenCaptureService.compose(rect: CGRect(x: -50, y: 0, width: 10, height: 10), tiles: [
            .init(frame: CGRect(x: 0, y: 0, width: 10, height: 10), image: image)
        ]))
    }

    func testLongScreenshotRejectsChangedPixelDimensionsAndKeepsSingleFrame() throws {
        let service = LongScreenshotService(screenshotService: SystemScreenshotService())
        let small = try bitmap(width: 20, height: 20, color: CGColor(gray: 1, alpha: 1))
        let large = try bitmap(width: 40, height: 40, color: CGColor(gray: 1, alpha: 1))
        XCTAssertFalse(service.isMostlySame(small, large))
        XCTAssertThrowsError(try service.stitch(frames: [small, large]))
        let result = try service.stitch(frames: [large])
        XCTAssertEqual(result.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 40)
    }
}
