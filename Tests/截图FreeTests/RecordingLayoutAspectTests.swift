import AppKit
import AVFoundation
import AVKit
import XCTest
@testable import 截图Free

@MainActor
final class RecordingLayoutAspectTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testSingleRowCentersAndNegativeScreenBounds() throws {
        _ = NSApplication.shared
        for visible in [CGRect(x: -1600, y: -900, width: 1400, height: 850), CGRect(x: -500, y: 50, width: 480, height: 320)] {
            for edge in [false, true] {
                let selection = CGRect(x: edge ? visible.minX : visible.midX - 100, y: visible.minY, width: 200, height: 140)
                let options = RecordingOptionsWindowController(selectionRect: selection, visibleFrame: visible)
                let control = RecordingControlWindowController(selectionRect: selection, audioSource: .both, quality: .original, visibleFrame: visible)
                defer { options.close(); control.close() }
                for window in [options.window, control.window] {
                    let root = try XCTUnwrap(window.contentView)
                    root.layoutSubtreeIfNeeded()
                    let glass = try XCTUnwrap(descendants(root).compactMap { $0 as? GlassView }.first)
                    // 检查应用布局的直接控件，不把原生 popup 内部文字基线当作整只按钮的中心。
                    let controls = descendants(glass.controlsHost).compactMap { $0 as? NSControl }.filter { view in
                        guard view is NSTextField || view is NSButton else { return false }
                        var ancestor = view.superview
                        while let parent = ancestor, parent !== glass.controlsHost {
                            if parent is NSControl { return false }
                            ancestor = parent.superview
                        }
                        return true
                    }
                    XCTAssertFalse(controls.isEmpty)
                    for view in controls {
                        let frame = view.convert(view.bounds, to: root)
                        XCTAssertEqual(frame.midY, glass.frame.midY, accuracy: 0.01)
                        XCTAssertTrue(root.bounds.contains(frame))
                    }
                    XCTAssertTrue(visible.contains(window.frame), "\(visible) / \(window.frame)")
                    if !edge { XCTAssertEqual(window.frame.midX, selection.midX, accuracy: 0.01) }
                    XCTAssertEqual(glass.frame.midX, root.bounds.midX, accuracy: 0.01)
                }
                let popups = descendants(try XCTUnwrap(options.window.contentView)).compactMap { $0 as? NSPopUpButton }
                XCTAssertEqual(popups.map(\.numberOfItems), [RecordingAudioSource.allCases.count, RecordingQuality.allCases.count])
            }
        }
    }

    func testPortraitUltrawideSquareLargeAndRotatedGeometry() {
        let visible = CGRect(x: -1200, y: -800, width: 1000, height: 700)
        for size in [CGSize(width: 1080, height: 1920), CGSize(width: 4000, height: 400), CGSize(width: 600, height: 600), CGSize(width: 7680, height: 4320), CGSize(width: 40, height: 500)] {
            let layout = RecordingPreviewLayout(movie: size, toolbarSize: CGSize(width: 200, height: 52), visible: visible)
            XCTAssertEqual(layout.media.width / layout.media.height, size.width / size.height, accuracy: 0.00001)
            XCTAssertLessThanOrEqual(layout.root.width, visible.width)
            XCTAssertLessThanOrEqual(layout.root.height, visible.height)
            XCTAssertEqual(layout.media.midX, layout.root.width / 2)
            XCTAssertEqual(layout.toolbar.midX, layout.root.width / 2)
            XCTAssertEqual(layout.toolbar.width, 200)
            XCTAssertEqual(layout.media.minY - layout.toolbar.maxY, 20)
        }
        let rotated = RecordingMovieGeometry.displaySize(CGSize(width: 320, height: 180), transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0))
        XCTAssertEqual(rotated, CGSize(width: 180, height: 320))
        XCTAssertFalse(RecordingMovieGeometry.valid(CGSize(width: CGFloat.infinity, height: 1)))
    }

    private func fixture(rotated: Bool) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), 127, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData && Date() < deadline { await Task.yield() }
        XCTAssertTrue(input.isReadyForMoreMediaData)
        XCTAssertTrue(adaptor.append(pixel, withPresentationTime: .zero))
        XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: 1, timescale: 10)))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    func testRealAssetRotationPreviewAndUnchangedExport() async throws {
        _ = NSApplication.shared
        for rotated in [false, true] {
            let url = try await fixture(rotated: rotated)
            let bytes = try Data(contentsOf: url)
            let loadedSize = try await RecordingMovieGeometry.load(url)
            let size = try XCTUnwrap(loadedSize)
            XCTAssertEqual(size.width / size.height, rotated ? 180.0 / 320 : 320.0 / 180, accuracy: 0.001)
            let destination = url.deletingLastPathComponent().appendingPathComponent("export-\(UUID()).mov")
            defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: url) }
            var cancel = true
            let controller = RecordingPreviewWindowController(url: url, chooseDestination: { cancel ? nil : destination })
            defer { controller.window.close() }
            let deadline = Date().addingTimeInterval(10)
            while controller.movieSize == nil && Date() < deadline { await Task.yield() }
            XCTAssertNotNil(controller.movieSize)
            let root = try XCTUnwrap(controller.window.contentView)
            root.layoutSubtreeIfNeeded()
            let player = try XCTUnwrap(descendants(root).compactMap { $0 as? AVPlayerView }.first)
            XCTAssertEqual(player.frame.width / player.frame.height, size.width / size.height, accuracy: 0.001)
            XCTAssertEqual(player.videoGravity, .resizeAspect)
            XCTAssertEqual(player.controlsStyle, .floating)
            XCTAssertFalse(player.showsFullScreenToggleButton)
            XCTAssertFalse(controller.window.styleMask.contains(.titled))
            XCTAssertTrue(controller.window.canBecomeKey)
            XCTAssertNil(controller.window.standardWindowButton(.closeButton))
            XCTAssertNil(root.hitTest(root.convert(NSPoint(x: 1, y: 1), to: root.superview)))
            let glass = try XCTUnwrap(descendants(root).compactMap { $0 as? GlassView }.first)
            XCTAssertTrue(glass.dragsWindowOnBackground)
            XCTAssertEqual(glass.frame.midX, root.bounds.midX, accuracy: 0.001)
            let buttons = descendants(glass).compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.count, 2)
            XCTAssertEqual(glass.frame.width, buttons.reduce(0) { $0 + $1.frame.width } + 44, accuracy: 0.001)
            let save = try XCTUnwrap(buttons.first { $0.title == "保存导出" })
            var closes = 0
            controller.onClose = { closes += 1 }
            save.performClick(nil)
            XCTAssertEqual(closes, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            cancel = false
            save.performClick(nil)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertEqual(closes, 1)
            XCTAssertNil(controller.window.contentView)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testLateAsyncResultAfterEscapeCannotReviveWindow() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("race-\(UUID()).mov")
        try Data("自建竞态文件".utf8).write(to: url)
        var continuation: CheckedContinuation<CGSize?, Never>?
        var finished = false
        let controller = RecordingPreviewWindowController(url: url, sizeLoader: { _ in
            let size = await withCheckedContinuation { continuation = $0 }
            finished = true
            return size
        })
        while continuation == nil { await Task.yield() }
        var closes = 0
        controller.onClose = { closes += 1 }
        controller.window.cancelOperation(nil)
        continuation?.resume(returning: CGSize(width: 500, height: 1000))
        while !finished { await Task.yield() }
        await Task.yield()
        controller.show()
        XCTAssertFalse(controller.window.isVisible)
        XCTAssertNil(controller.window.contentView)
        XCTAssertNil(controller.movieSize)
        XCTAssertEqual(closes, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
