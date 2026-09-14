import AppKit
import XCTest
@testable import 截图Free

final class LongCapturePipelineTests: XCTestCase {
    private func bitmap(width: Int = 40, height: Int = 80) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<height {
            context.setFillColor(CGColor(red: CGFloat((y * 37) % 251) / 255,
                green: CGFloat((y * 71) % 251) / 255, blue: CGFloat((y * 13) % 251) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testDeniedPermissionDoesNotReturnDesktopAsSuccessfulCapture() {
        var attemptedCapture = false
        let service = ScreenCaptureService(hasScreenAccess: { false }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]
        }, captureDisplay: { _ in attemptedCapture = true; return nil }, captureQuartzRect: { _ in
            XCTFail("未授权时不应回退"); return nil
        })
        XCTAssertThrowsError(try service.captureCGImage(rect: CGRect(x: 0, y: 0, width: 40, height: 40))) {
            guard case ScreenCaptureError.screenRecordingPermissionRequired = $0 else {
                return XCTFail("应返回明确的权限错误，实际为 \($0)")
            }
        }
        XCTAssertFalse(attemptedCapture)
    }

    func testDisplayFallbackRetainsMixedDPIScaleAndUsesPrimaryOrigin() throws {
        let primary = CGRect(x: 0, y: 0, width: 100, height: 100)
        let above = CGRect(x: 0, y: 100, width: 100, height: 100)
        let retina = try bitmap(width: 200, height: 200)
        let standard = try bitmap(width: 100, height: 100)
        var fallbackRects: [CGRect] = []
        let service = ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: primary), .init(id: 2, frame: above)]
        }, captureDisplay: { $0 == 1 ? retina : nil }, captureQuartzRect: {
            fallbackRects.append($0); return standard
        })
        let result = try service.captureCGImage(rect: CGRect(x: 10, y: 80, width: 40, height: 40))
        XCTAssertEqual(fallbackRects, [CGRect(x: 0, y: -100, width: 100, height: 100)])
        XCTAssertEqual(result.width, 80)
        XCTAssertEqual(result.height, 80)
    }

    func testFailedFallbackThrowsRatherThanReturningPartialDesktop() throws {
        let image = try bitmap()
        let service = ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80)),
             .init(id: 2, frame: CGRect(x: 40, y: 0, width: 40, height: 80))]
        }, captureDisplay: { $0 == 1 ? image : nil }, captureQuartzRect: { _ in nil })
        XCTAssertThrowsError(try service.captureCGImage(rect: CGRect(x: 0, y: 0, width: 80, height: 80)))
    }

    func testIdenticalFramesDoNotExtendLongScreenshot() throws {
        let first = try bitmap()
        let second = try bitmap()
        let service = LongScreenshotService(screenshotService: SystemScreenshotService())
        let result = try service.stitch(frames: [first, second, first])
        let output = try XCTUnwrap(result.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(output.width, first.width)
        XCTAssertEqual(output.height, first.height)
    }

    func testKnownOverlapPreservesTopToBottomContent() throws {
        let source = try bitmap(height: 120)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 80)))
        let second = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 40, width: 40, height: 80)))
        let service = LongScreenshotService(screenshotService: SystemScreenshotService())
        let result = try service.stitch(frames: [first, second])
        let output = try XCTUnwrap(result.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(output.height, 120)
        XCTAssertTrue(service.isMostlySame(source, output, threshold: 0.001))
    }

    func testSmallScrollAndManyFramesPreservePixels() throws {
        let source = try bitmap(height: 160)
        let frames = try stride(from: 0, through: 80, by: 5).map { y in
            try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: y, width: 40, height: 80)))
        }
        let service = LongScreenshotService(screenshotService: SystemScreenshotService())
        let result = try service.stitch(frames: frames)
        let output = try XCTUnwrap(result.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertTrue(service.imagesAreIdentical(source, output))
    }

    func testNoOverlapAndAmbiguousContentAreRejected() throws {
        let service = LongScreenshotService(screenshotService: SystemScreenshotService())
        let source = try bitmap(height: 200)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 80)))
        let unrelated = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 110, width: 40, height: 80)))
        XCTAssertThrowsError(try service.stitch(frames: [first, unrelated]))
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 80, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.95, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        let blank = try XCTUnwrap(context.makeImage())
        context.setFillColor(CGColor(gray: 0.94, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        XCTAssertThrowsError(try service.stitch(frames: [blank, XCTUnwrap(context.makeImage())]))
    }

    func testBudgetAndAdaptiveScrollStep() throws {
        let frame = try bitmap()
        let service = LongScreenshotService(screenshotService: SystemScreenshotService(), byteLimit: 100)
        XCTAssertThrowsError(try service.stitch(frames: [frame]))
        XCTAssertEqual(LongScreenshotService.scrollStep(height: 100), 35)
        XCTAssertEqual(LongScreenshotService.scrollStep(height: .nan), 1)
        XCTAssertEqual(LongScreenshotService.scrollStep(height: 1200), 420)
    }

    @MainActor
    func testCoordinatorWaitsForFirstFrameAndFinishCapturesTail() async throws {
        _ = NSApplication.shared
        let source = try bitmap(height: 120)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 80)))
        let second = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 40, width: 40, height: 80)))
        let captured = expectation(description: "首帧捕获")
        let scrolled = expectation(description: "首帧完成后才滚动")
        let finished = expectation(description: "结束时捕获最终页面")
        var captureCount = 0
        var didScroll = false
        let service = ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in
            captureCount += 1
            if captureCount == 1 { XCTAssertFalse(didScroll); captured.fulfill(); return first }
            return second
        }, captureQuartzRect: { _ in nil })
        let coordinator = AppCoordinator(captureService: service,
            settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            postLongScroll: { _, _ in
                XCTAssertGreaterThanOrEqual(captureCount, 1)
                didScroll = true
                scrolled.fulfill()
            }, onLongImage: { image in
                XCTAssertEqual(image.size.height, 120)
                finished.fulfill()
            })
        coordinator.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .automatic)
        await fulfillment(of: [captured, scrolled], timeout: 3)
        coordinator.finishManualLongCapture()
        coordinator.finishManualLongCapture()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(coordinator.longCaptureIsRunning)
        XCTAssertGreaterThanOrEqual(captureCount, 2)
    }

    @MainActor
    func testFinishBeforeFirstFrame() async throws {
        _ = NSApplication.shared
        let frame = try bitmap()
        let finished = expectation(description: "首帧完成后结束")
        let service = ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in frame }, captureQuartzRect: { _ in nil })
        let coordinator = AppCoordinator(captureService: service,
            settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            postLongScroll: { _, _ in XCTFail("结束后不可滚动") }, onLongImage: { _ in finished.fulfill() })
        coordinator.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .automatic)
        coordinator.finishManualLongCapture()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(coordinator.longCaptureIsRunning)
    }

    func testFixedHeaderFooterRejectedAndLocalDynamicContentTolerated() throws {
        let source = try bitmap(height: 120)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 80)))
        let second = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 40, width: 40, height: 80)))
        func changed(_ image: CGImage, y: Int) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 80, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 80))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 80 - y - 8, width: 40, height: 8))
            return try XCTUnwrap(context.makeImage())
        }
        let service = LongScreenshotService(screenshotService: SystemScreenshotService())
        XCTAssertThrowsError(try service.stitch(frames: [changed(first, y: 0), changed(second, y: 0)]))
        XCTAssertThrowsError(try service.stitch(frames: [changed(first, y: 72), changed(second, y: 72)]))
        XCTAssertEqual(try service.validatedOverlap(previous: first, current: changed(second, y: 16)), 40)
    }

    @MainActor
    func testCaptureFailureResetsSessionAndAllowsRestart() async throws {
        _ = NSApplication.shared
        let failed = expectation(description: "失败清理")
        let finished = expectation(description: "失败后可以重新开始")
        let frame = try bitmap()
        var allowed = false
        let service = ScreenCaptureService(hasScreenAccess: { allowed }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in frame }, captureQuartzRect: { _ in nil })
        let coordinator = AppCoordinator(captureService: service,
            settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            postLongScroll: { _, _ in XCTFail("失败或结束后不可滚动") },
            onLongImage: { _ in finished.fulfill() }, onLongError: { _ in failed.fulfill() })
        let rect = CGRect(x: 0, y: 0, width: 40, height: 80)
        coordinator.beginLongCapture(rect: rect, mode: .automatic)
        coordinator.finishManualLongCapture()
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertFalse(coordinator.longCaptureIsRunning)
        allowed = true
        coordinator.beginLongCapture(rect: rect, mode: .manual)
        coordinator.finishManualLongCapture()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(coordinator.longCaptureIsRunning)
    }

    @MainActor
    func testContinuousScrollIsThrottledAndCancellationRejectsLateFrame() async throws {
        _ = NSApplication.shared
        let frame = try bitmap()
        let firstCapture = expectation(description: "首帧完成")
        let nextCapture = expectation(description: "持续滚动期间采样")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var count = 0
        let service = ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in
            count += 1
            if count == 1 { firstCapture.fulfill() }
            else if count == 2 {
                started.signal()
                nextCapture.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
            return frame
        }, captureQuartzRect: { _ in nil })
        let coordinator = AppCoordinator(captureService: service,
            settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            postLongScroll: { _, _ in XCTFail("手动模式不能发滚动事件") },
            onLongImage: { _ in XCTFail("取消后不能交付迟到帧") }, onLongError: { _ in XCTFail("取消不应污染下一会话") })
        coordinator.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .manual)
        await fulfillment(of: [firstCapture], timeout: 3)
        // 模拟连续事件流，间隔始终小于采样窗口；使用 XCTest 期限而非依赖硬件事件。
        let events = Task { @MainActor in
            for _ in 0..<15 {
                coordinator.scheduleLongCaptureAfterScroll(direction: .down)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        await fulfillment(of: [nextCapture], timeout: 0.6)
        XCTAssertEqual(started.wait(timeout: .now()), .success)
        coordinator.cancelLongCapture()
        release.signal()
        await events.value
        XCTAssertFalse(coordinator.longCaptureIsRunning)
    }

    @MainActor
    func testCaptureHidesBothOverlayWindowsAndCloseCannotResurrectThem() throws {
        _ = NSApplication.shared
        let before = Set(NSApp.windows.map(\.windowNumber))
        let overlay = LongScreenshotProgressOverlayController(selectionRect: CGRect(x: 100, y: 100, width: 80, height: 100))
        let windows = NSApp.windows.filter { !before.contains($0.windowNumber) }
        XCTAssertEqual(windows.count, 2)
        overlay.show()
        overlay.setSelectionBorderHidden(true)
        XCTAssertTrue(windows.allSatisfy { !$0.isVisible })
        overlay.updatePreview(image: NSImage(cgImage: try bitmap(), size: CGSize(width: 40, height: 80)), frameCount: 1)
        XCTAssertTrue(windows.allSatisfy { !$0.isVisible }, "捕获期间预览刷新不能重新显示浮层")
        overlay.setSelectionBorderHidden(false)
        XCTAssertTrue(windows.contains { $0.isVisible })
        overlay.close()
        overlay.setSelectionBorderHidden(false)
        XCTAssertTrue(windows.allSatisfy { !$0.isVisible }, "关闭后的迟到回调不能复活窗口")
    }
}
