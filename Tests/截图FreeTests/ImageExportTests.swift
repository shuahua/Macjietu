import AppKit
import XCTest
@testable import 截图Free

@MainActor
final class ImageExportTests: XCTestCase {
    private func source(retina: Bool) throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<16 {
            for x in 0..<24 {
                let value: CGFloat = (x + y).isMultiple(of: 2) ? 0 : 1
                bitmap.setColor(NSColor(deviceRed: value, green: value, blue: value, alpha: 1), atX: x, y: y)
            }
        }
        return NSImage(cgImage: try XCTUnwrap(bitmap.cgImage),
                       size: CGSize(width: retina ? 12 : 24, height: retina ? 8 : 16))
    }

    private func png(_ image: NSImage) throws -> NSBitmapImageRep {
        let data = try ImageEncoding.pngData(from: image)
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    func testThreeScalesUseNativePixelsRegardlessOfRetinaAndPreviewZoom() throws {
        for retina in [false, true] {
            let image = try source(retina: retina)
            let canvas = AnnotationCanvasView(frame: CGRect(x: 0, y: 0, width: 12, height: 8), image: image)
            for scale in 1...3 {
                let bitmap = try png(canvas.renderedImage(scale: CGFloat(scale)))
                XCTAssertEqual(bitmap.pixelsWide, 24 * scale)
                XCTAssertEqual(bitmap.pixelsHigh, 16 * scale)
                canvas.setCanvasDisplaySize(CGSize(width: 36, height: 24))
                let zoomed = try png(canvas.renderedImage(scale: CGFloat(scale)))
                XCTAssertEqual(zoomed.pixelsWide, bitmap.pixelsWide)
                XCTAssertEqual(zoomed.pixelsHigh, bitmap.pixelsHigh)
            }
        }
    }

    func testOriginalPreservesEveryCheckerboardPixel() throws {
        let image = try source(retina: true)
        let canvas = AnnotationCanvasView(frame: CGRect(x: 0, y: 0, width: 7, height: 5), image: image)
        let bitmap = try png(canvas.renderedImage())
        for y in 0..<16 {
            for x in 0..<24 {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(color.redComponent, (x + y).isMultiple(of: 2) ? 0 : 1, accuracy: 0.01)
            }
        }
        let enlarged = try png(canvas.renderedImage(scale: 2))
        XCTAssertTrue((0..<48).contains { x in
            guard let color = enlarged.colorAt(x: x, y: 8)?.usingColorSpace(.deviceRGB) else { return false }
            return color.redComponent > 0.05 && color.redComponent < 0.95
        }, "插值会产生中间色，不是新增源细节")
    }

    func testAnnotatedRetinaOutputKeepsNativeResolution() throws {
        _ = NSApplication.shared
        let canvas = AnnotationCanvasView(frame: CGRect(x: 0, y: 0, width: 24, height: 16), image: try source(retina: true))
        canvas.tool = .text
        canvas.beginText(at: CGPoint(x: 2, y: 14))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.string = "A"
        canvas.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        for scale in 1...3 {
            let bitmap = try png(canvas.renderedImage(scale: CGFloat(scale)))
            XCTAssertEqual(bitmap.pixelsWide, 24 * scale)
            XCTAssertEqual(bitmap.pixelsHigh, 16 * scale)
        }
    }

    func testEncodingChoosesLargestRepresentationNotPoints() throws {
        let image = NSImage(size: CGSize(width: 12, height: 8))
        let small = try png(source(retina: false))
        let large = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        image.addRepresentation(small)
        image.addRepresentation(large)
        XCTAssertEqual(try png(image).pixelsWide, 48)
        XCTAssertEqual(try png(image).pixelsHigh, 32)
    }

    func testRecordingQualitiesRemainDistinct() {
        XCTAssertEqual(RecordingQuality.allCases.count, 3)
        XCTAssertEqual(RecordingQuality.standard.outputScale, 0.75)
        XCTAssertEqual(RecordingQuality.high.outputScale, 1)
        XCTAssertEqual(RecordingQuality.original.outputScale, 1)
        let rates = RecordingQuality.allCases.map { $0.bitRate(width: 1920, height: 1080) }
        XCTAssertEqual(Set(rates).count, 3)
        XCTAssertEqual(rates[1], rates[0] * 2)
        XCTAssertEqual(rates[2], rates[0] * 4)
    }
}
