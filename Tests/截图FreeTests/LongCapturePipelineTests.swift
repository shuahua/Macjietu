import AppKit
import XCTest
@testable import 截图Free

final class LongCapturePipelineTests: XCTestCase {
    // 管线测试的系统边界完全注入，浮层排除也不能意外读取真实桌面。
    private func ScreenCaptureService(hasScreenAccess: @escaping () -> Bool,
        currentDisplays: @escaping () -> [CaptureDisplay],
        captureDisplay: @escaping (CGDirectDisplayID) -> CGImage?,
        captureQuartzRect: @escaping (CGRect) -> CGImage?) -> 截图Free.ScreenCaptureService {
        截图Free.ScreenCaptureService(hasScreenAccess: hasScreenAccess, currentDisplays: currentDisplays,
            captureDisplay: captureDisplay, captureQuartzRect: captureQuartzRect,
            windowList: { [[kCGWindowNumber as String: UInt32(1), kCGWindowOwnerPID as String: Int32(-1)]] },
            captureWindows: { _, _ in captureDisplay(currentDisplays().first!.id) })
    }
    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "等待状态超时", file: file, line: line)
    }

    @MainActor
    private func coordinator(frame: CGImage, onImage: ((NSImage) -> Void)?,
                             onError: @escaping (Error) -> Void = { XCTFail("意外错误：\($0)") },
                             stitch: (([CGImage]) async throws -> CGImage)? = nil) -> AppCoordinator {
        _ = NSApplication.shared
        return AppCoordinator(captureService: ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in frame }, captureQuartzRect: { _ in nil }),
        settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        postLongScroll: { _, _ in }, onLongImage: onImage, onLongError: onError, stitchLongFrames: stitch)
    }

    @MainActor
    func testIdenticalAutomaticFramesNeverClaimCompletionAndExplicitFinishCanRestart() async throws {
        let frame = try bitmap()
        let rect = CGRect(x: 0, y: 0, width: 40, height: 80)
        var images: [NSImage] = []
        var app: AppCoordinator!
        app = coordinator(frame: frame, onImage: { image in
            XCTAssertFalse(Task.isCancelled, "结果回调不能处于自取消任务中")
            XCTAssertTrue(app.longCaptureResourcesAreReset)
            images.append(image)
            if images.count == 1 { app.beginLongCapture(rect: rect, mode: .automatic) }
        })
        defer { app.cancelLongCapture(); app = nil }
        app.beginLongCapture(rect: rect, mode: .automatic)
        try await waitUntil { app.longCaptureFrameCount == 1 }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertTrue(app.longCaptureIsRunning)
        XCTAssertEqual(images.count, 0, "静态帧不能证明到底")
        app.finishManualLongCapture()
        try await waitUntil { images.count == 1 && app.longCaptureFrameCount == 1 }
        app.finishManualLongCapture()
        try await waitUntil { images.count == 2 }
        XCTAssertTrue(app.longCaptureResourcesAreReset)
        XCTAssertEqual(images.map(\.size.height), [80, 80])
    }

    @MainActor
    func testOldOverlayFinishCallbackCannotFinishNewSessionAndEditorsSurvive() async throws {
        let app = coordinator(frame: try bitmap(), onImage: nil)
        let rect = CGRect(x: 0, y: 0, width: 40, height: 80)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer { app.cancelLongCapture(); for window in NSApp.windows where !existing.contains(ObjectIdentifier(window)) { window.close() } }
        app.beginLongCapture(rect: rect, mode: .manual)
        try await waitUntil { app.longCaptureFrameCount == 1 }
        let oldOverlay = try XCTUnwrap(app.longCaptureProgressOverlay)
        let lateFinish = try XCTUnwrap(oldOverlay.onDoubleClickSelection)
        lateFinish()
        try await waitUntil { app.retainedEditors.count == 1 }
        XCTAssertTrue(app.longCaptureResourcesAreReset)
        let firstEditor = app.retainedEditors[0]
        let firstWindows = NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) && $0.isVisible }
        XCTAssertFalse(firstWindows.isEmpty)
        app.beginLongCapture(rect: rect, mode: .manual)
        lateFinish()
        try await waitUntil { app.longCaptureFrameCount == 1 }
        XCTAssertTrue(app.longCaptureIsRunning)
        XCTAssertNotNil(app.longCaptureProgressOverlay)
        XCTAssertNil(oldOverlay.onDoubleClickSelection)
        app.finishManualLongCapture()
        try await waitUntil { app.retainedEditors.count == 2 }
        XCTAssertTrue(app.retainedEditors[0] === firstEditor)
        XCTAssertTrue(firstWindows.allSatisfy(\.isVisible))
        XCTAssertNotNil(firstEditor.exportImage())
        XCTAssertNotNil(app.retainedEditors[1].exportImage())
        XCTAssertTrue(app.longCaptureResourcesAreReset)
    }

    @MainActor
    func testAsyncStitchFailureRecoversOriginalAndReportsError() async throws {
        let frame = try bitmap()
        var images: [NSImage] = []
        var errors = 0
        let app = coordinator(frame: frame, onImage: { images.append($0) }, onError: { _ in errors += 1 }, stitch: { _ in
            await Task.yield()
            throw LongScreenshotError.noFramesCaptured
        })
        app.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .manual)
        app.finishManualLongCapture()
        try await waitUntil { errors == 1 }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.size.height, 80)
        XCTAssertTrue(app.longCaptureResourcesAreReset)
    }

    @MainActor
    func testExplicitFinishRejectedTailDeliversValidatedImageWithoutWarningAcrossSessions() async throws {
        _ = NSApplication.shared
        let source = try bitmap(height: 200)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 80)))
        let unrelated = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 110, width: 40, height: 80)))
        var count = 0
        var images: [NSImage] = []
        var errors = 0
        let app = AppCoordinator(captureService: ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in count += 1; return count == 1 ? first : unrelated }, captureQuartzRect: { _ in nil }),
        settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        postLongScroll: { _, _ in }, onLongImage: { images.append($0) }, onLongError: { _ in errors += 1 })
        defer { app.cancelLongCapture() }
        for session in 1...2 {
            count = 0
            app.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .manual)
            try await waitUntil { app.longCaptureFrameCount == 1 }
            app.finishManualLongCapture()
            app.finishManualLongCapture() // 重复点击不能重复交付。
            try await waitUntil { images.count == session }
            XCTAssertEqual(errors, 0)
            XCTAssertEqual(app.longCaptureLastNotice, "已按当前内容结束，尾部未确认。", "用户完成不报错，但不能把被拒尾部谎报完整")
            let recovered = try XCTUnwrap(images.last?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertTrue(LongScreenshotService(screenshotService: SystemScreenshotService()).imagesAreIdentical(first, recovered))
            XCTAssertTrue(app.longCaptureResourcesAreReset)
        }
    }

    @MainActor
    func testExplicitFinishStillReportsPermissionAndCaptureFailuresIncludingZeroFrames() async throws {
        _ = NSApplication.shared
        let frame = try bitmap()
        for hasFirstFrame in [false, true] {
            for deniedPermission in [false, true] {
                let lock = NSLock()
                var failing = !hasFirstFrame
                func shouldFail() -> Bool { lock.lock(); defer { lock.unlock() }; return failing }
                var images: [NSImage] = []
                var errors: [Error] = []
                let app = AppCoordinator(captureService: ScreenCaptureService(
                    hasScreenAccess: { !(deniedPermission && shouldFail()) }, currentDisplays: {
                        [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
                    }, captureDisplay: { _ in shouldFail() ? nil : frame }, captureQuartzRect: { _ in nil }),
                    settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                    postLongScroll: { _, _ in }, onLongImage: { images.append($0) }, onLongError: { errors.append($0) })
                app.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .manual)
                if hasFirstFrame {
                    try await waitUntil { app.longCaptureFrameCount == 1 }
                    lock.withLock { failing = true }
                }
                app.finishManualLongCapture()
                try await waitUntil { errors.count == 1 }
                XCTAssertEqual(images.count, hasFirstFrame ? 1 : 0, "零帧失败不可交付成功图片")
                XCTAssertTrue(errors[0] is ScreenCaptureError)
                XCTAssertTrue(app.longCaptureResourcesAreReset)
                app.cancelLongCapture()
            }
        }
    }

    @MainActor
    func testExplicitFinishStillReportsStorageFailure() async throws {
        var images = 0
        var errors: [Error] = []
        let app = coordinator(frame: try bitmap(), onImage: { _ in images += 1 },
            onError: { errors.append($0) }, stitch: { _ in
                throw CocoaError(.fileWriteOutOfSpace)
            })
        defer { app.cancelLongCapture() }
        app.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .manual)
        try await waitUntil { app.longCaptureFrameCount == 1 }
        app.finishManualLongCapture()
        try await waitUntil { errors.count == 1 }
        XCTAssertEqual((errors[0] as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        XCTAssertEqual(images, 1, "真实错误可恢复已有图，但仍必须报告错误")
        XCTAssertTrue(app.longCaptureResourcesAreReset)
    }

    @MainActor
    func testAutomaticFinalBudgetFailureStillReportsPartialResult() async throws {
        var images = 0
        var errors = 0
        let app = coordinator(frame: try bitmap(), onImage: { _ in images += 1 },
            onError: { _ in errors += 1 }, stitch: { _ in throw LongScreenshotError.memoryLimit })
        defer { app.cancelLongCapture() }
        app.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .automatic)
        try await waitUntil { app.longCaptureFrameCount == 1 }
        app.finishManualLongCapture()
        try await waitUntil { errors == 1 }
        XCTAssertEqual(images, 1)
        XCTAssertEqual(app.longCaptureLastNotice, "已达安全上限，已保留连续内容，请检查尾部。")
        XCTAssertTrue(app.longCaptureResourcesAreReset)
    }

    @MainActor
    func testCancelledAsyncStitchCannotClearImmediatelyRestartedSession() async throws {
        let frame = try bitmap()
        var continuation: CheckedContinuation<CGImage, Error>?
        var attempts = 0
        var results = 0
        let app = coordinator(frame: frame, onImage: { _ in results += 1 }, stitch: { _ in
            attempts += 1
            if attempts == 1 { return try await withCheckedThrowingContinuation { continuation = $0 } }
            return frame
        })
        let rect = CGRect(x: 0, y: 0, width: 40, height: 80)
        app.beginLongCapture(rect: rect, mode: .manual)
        app.finishManualLongCapture()
        try await waitUntil { continuation != nil }
        app.cancelLongCapture()
        app.beginLongCapture(rect: rect, mode: .manual)
        continuation?.resume(throwing: LongScreenshotError.noFramesCaptured)
        continuation = nil
        try await waitUntil { app.longCaptureFrameCount == 1 }
        XCTAssertTrue(app.longCaptureIsRunning)
        XCTAssertEqual(results, 0)
        app.finishManualLongCapture()
        try await waitUntil { results == 1 }
        XCTAssertTrue(app.longCaptureResourcesAreReset)
    }

    @MainActor
    func testScrollBeforeFirstFrameStillSamplesAfterIt() async throws {
        _ = NSApplication.shared
        let frame = try bitmap()
        let sampled = expectation(description: "首帧期间的滚动不能丢失")
        var count = 0
        let app = AppCoordinator(captureService: ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in count += 1; if count == 2 { sampled.fulfill() }; return frame }, captureQuartzRect: { _ in nil }),
        settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        postLongScroll: { _, _ in }, onLongImage: { _ in })
        defer { app.cancelLongCapture() }
        app.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .manual)
        app.scheduleLongCaptureAfterScroll(direction: .down)
        await fulfillment(of: [sampled], timeout: 2)
    }

    @MainActor
    func testManualEventsMomentumInFlightTailPreviewAndTwoSessions() async throws {
        _ = NSApplication.shared
        let source = try bitmap(height: 140)
        let frames = try [0, 20, 40, 60].map { y in
            try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: y, width: 40, height: 80)))
        }
        let lock = NSLock()
        var position = 0
        var images: [NSImage] = []
        let app = AppCoordinator(captureService: ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in lock.lock(); defer { lock.unlock() }; return frames[position] }, captureQuartzRect: { _ in nil }),
        settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        postLongScroll: { _, _ in XCTFail("手动不能自动滚动") }, onLongImage: { images.append($0) },
        onLongError: { XCTFail("意外错误 \($0)") })
        func move(_ value: Int) { lock.lock(); position = value; lock.unlock() }
        defer { app.cancelLongCapture() }
        for session in 1...2 {
            move(0)
            app.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .manual)
            try await waitUntil { app.longCaptureFrameCount == 1 }
            move(1)
            // 合成真实 NSEvent，经过本地监听器再返回原事件，不能吞掉页面滚动。
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
            cg.location = CGPoint(x: 20, y: (NSScreen.screens.first?.frame.maxY ?? 0) - 40)
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            NSApp.sendEvent(event)
            try await waitUntil { app.longCaptureFrameCount == 2 }
            let preview = try XCTUnwrap(app.longCaptureProgressOverlay?.previewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let expected = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 100)))
            XCTAssertTrue(LongScreenshotService(screenshotService: SystemScreenshotService()).imagesAreIdentical(preview, expected))
            // 错误方向提示不能推翻像素证据；phase 开始后惯性可在鼠标移出时继续。
            app.handleLongCaptureScroll(deltaY: 1, point: CGPoint(x: 20, y: 40), phase: .began)
            move(2)
            try await Task.sleep(nanoseconds: 140_000_000)
            app.handleLongCaptureScroll(deltaY: 1, point: CGPoint(x: 200, y: 400), momentum: .changed)
            try await waitUntil { app.longCaptureFrameCount == 3 }
            move(3)
            app.handleLongCaptureScroll(deltaY: 0, point: CGPoint(x: 200, y: 400), momentum: .ended)
            try await waitUntil { app.longCaptureFrameCount == 4 }
            app.finishManualLongCapture()
            try await waitUntil { images.count == session }
            let result = try XCTUnwrap(images.last?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertTrue(LongScreenshotService(screenshotService: SystemScreenshotService()).imagesAreIdentical(source, result))
            XCTAssertTrue(app.longCaptureResourcesAreReset)
        }
    }

    @MainActor
    func testScrollDuringBlockedCaptureQueuesAnotherSampleAndFiltersOutside() async throws {
        _ = NSApplication.shared
        let frame = try bitmap()
        let blocked = expectation(description: "第二帧采集中")
        let followup = expectation(description: "采集中事件仍产生后续采样")
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var count = 0
        func capturedCount() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        let app = AppCoordinator(captureService: ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in
            lock.lock(); count += 1; let n = count; lock.unlock()
            if n == 2 { blocked.fulfill(); _ = release.wait(timeout: .now() + 3) }
            if n == 3 { followup.fulfill() }
            return frame
        }, captureQuartzRect: { _ in nil }),
        settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        postLongScroll: { _, _ in }, onLongImage: { _ in })
        defer { release.signal(); app.cancelLongCapture() }
        app.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .manual)
        try await waitUntil { app.longCaptureFrameCount == 1 }
        app.handleLongCaptureScroll(deltaY: -1, point: CGPoint(x: -200, y: 100))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(capturedCount(), 1, "选区外普通滚轮不能触发")
        app.handleLongCaptureScroll(deltaY: -1, point: CGPoint(x: 20, y: 40))
        await fulfillment(of: [blocked], timeout: 2)
        app.handleLongCaptureScroll(deltaY: -1, point: CGPoint(x: 20, y: 40), phase: .changed)
        release.signal()
        await fulfillment(of: [followup], timeout: 2)
    }

    func testUpwardExtensionRollbackAndBoundedPreview() throws {
        let service = LongScreenshotService(screenshotService: SystemScreenshotService())
        let source = try bitmap(height: 140)
        func frame(_ y: Int) throws -> CGImage {
            try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: y, width: 40, height: 80)))
        }
        var frames = [try frame(40)]
        frames = try service.merging(frame: frame(20), into: frames)
        frames = try service.merging(frame: frame(0), into: frames)
        XCTAssertEqual(try service.merging(frame: frame(10), into: frames).count, 3)
        frames = try service.merging(frame: frame(60), into: frames)
        let result = try service.stitch(frames: frames)
        XCTAssertTrue(service.imagesAreIdentical(source, try XCTUnwrap(result.cgImage(forProposedRect: nil, context: nil, hints: nil))))
        let preview = try service.stitch(frames: frames, maximumPreviewDimension: 70)
        XCTAssertEqual(preview.size, CGSize(width: 20, height: 70))
    }

    @MainActor
    func testPollingWithoutAnyScrollMonitorRecoversTransientMismatchAndCleansUp() async throws {
        _ = NSApplication.shared
        let source = try bitmap(height: 240)
        let frames = try [0, 20, 130, 40].map {
            try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: $0, width: 40, height: 80)))
        }
        let lock = NSLock()
        var count = 0
        var images: [NSImage] = []
        func sampleCount() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        let app = AppCoordinator(captureService: ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in
            lock.lock(); defer { lock.unlock() }
            let frame = frames[min(count, 3)]; count += 1; return frame
        }, captureQuartzRect: { _ in nil }),
        settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        postLongScroll: { _, _ in XCTFail("轮询不能自动滚动") }, onLongImage: { images.append($0) },
        onLongError: { XCTFail("暂态不匹配应恢复：\($0)") }, enableScrollMonitors: false)
        defer { app.cancelLongCapture() }
        app.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .manual)
        try await waitUntil { app.longCaptureFrameCount == 3 }
        XCTAssertGreaterThanOrEqual(sampleCount(), 4)
        app.finishManualLongCapture()
        try await waitUntil { images.count == 1 }
        XCTAssertEqual(images[0].size.height, 120)
        XCTAssertTrue(app.longCaptureResourcesAreReset)
        let stopped = sampleCount()
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertEqual(sampleCount(), stopped)
    }

    @MainActor
    func testPersistentGapReturnsOneStitchedPartialAfterBoundedRetries() async throws {
        _ = NSApplication.shared
        let source = try bitmap(height: 240)
        let frames = try [0, 20, 130].map {
            try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: $0, width: 40, height: 80)))
        }
        let lock = NSLock()
        var count = 0
        var images: [NSImage] = []
        var errors = 0
        let app = AppCoordinator(captureService: ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in
            lock.lock(); defer { lock.unlock() }
            let frame = frames[min(count, 2)]; count += 1; return frame
        }, captureQuartzRect: { _ in nil }),
        settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        postLongScroll: { _, _ in XCTFail("手动不能滚动") }, onLongImage: { images.append($0) },
        onLongError: { _ in errors += 1 }, enableScrollMonitors: false)
        defer { app.cancelLongCapture() }
        app.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .manual)
        try await waitUntil { errors == 1 }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.size.height, 100)
        XCTAssertTrue(app.longCaptureResourcesAreReset)
    }

    @MainActor
    func testAutomaticTransientGapResamplesWithoutPostingAnotherScroll() async throws {
        _ = NSApplication.shared
        let source = try bitmap(height: 240)
        let frames = try [0, 130, 20].map {
            try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: $0, width: 40, height: 80)))
        }
        let lock = NSLock()
        var count = 0
        var scrolls = 0
        var scrollsAtRecovery = -1
        let app = AppCoordinator(captureService: ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in
            lock.lock(); defer { lock.unlock() }
            if count == 2 { scrollsAtRecovery = scrolls }
            let frame = frames[min(count, 2)]; count += 1; return frame
        }, captureQuartzRect: { _ in nil }),
        settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        postLongScroll: { _, _ in lock.lock(); scrolls += 1; lock.unlock() }, onLongImage: { _ in XCTFail("不能自行完成") },
        onLongError: { XCTFail("暂态失败不能结束：\($0)") }, enableScrollMonitors: false)
        defer { app.cancelLongCapture() }
        app.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .automatic)
        try await waitUntil { app.longCaptureFrameCount == 2 }
        func postedAtRecovery() -> Int { lock.lock(); defer { lock.unlock() }; return scrollsAtRecovery }
        XCTAssertEqual(postedAtRecovery(), SmoothScroll.segments(delta: -12).count, "不匹配后不得开始另一批滚动")
        XCTAssertTrue(app.longCaptureIsRunning)
    }

    @MainActor
    func testAutomaticStitchedTailStopsWithoutWarningOrExtraCapture() async throws {
        _ = NSApplication.shared
        let source = try bitmap(height: 100)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 80)))
        let last = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 20, width: 40, height: 80)))
        let lock = NSLock()
        var count = 0
        var images: [NSImage] = []
        let app = AppCoordinator(captureService: ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 80))]
        }, captureDisplay: { _ in
            lock.withLock { count += 1; return count == 1 ? first : last }
        }, captureQuartzRect: { _ in nil }),
        settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        postLongScroll: { _, _ in }, onLongImage: { images.append($0) },
        onLongError: { XCTFail("自动无新增不应误告：\($0)") }, enableScrollMonitors: false)
        defer { app.cancelLongCapture() }
        app.beginLongCapture(rect: CGRect(x: 0, y: 0, width: 40, height: 80), mode: .automatic)
        try await waitUntil { images.count == 1 }
        XCTAssertTrue(app.longCaptureResourcesAreReset)
        XCTAssertNil(app.longCaptureLastNotice)
        XCTAssertEqual(lock.withLock { count }, 10, "连续八次无新增后直接渲染，不应再采尾帧")
        let result = try XCTUnwrap(images[0].cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertTrue(LongScreenshotService(screenshotService: SystemScreenshotService()).imagesAreIdentical(source, result))
    }

    func testZeroDisplacementNoiseDoesNotAppendButSparseNewContentIsNotSwallowed() throws {
        let service = LongScreenshotService(screenshotService: SystemScreenshotService())
        let frame = try bitmap()
        func changingPixel(amount: UInt8) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 80,
                bitsPerComponent: 8, bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 40, height: 80))
            let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            data[160 * 40 + 20 * 4] = data[160 * 40 + 20 * 4] &+ amount
            return try XCTUnwrap(context.makeImage())
        }
        let noise = try changingPixel(amount: 1)
        XCTAssertFalse(service.imagesAreIdentical(frame, noise))
        XCTAssertTrue(try service.hasNoNewContent(frame, noise))
        let plan = try service.merging(frame: frame, into: LongScreenshotService.StitchPlan())
        XCTAssertEqual(try service.merging(frame: noise, into: plan).frames.count, 1)
        XCTAssertFalse(try service.hasNoNewContent(frame, changingPixel(amount: 20)), "不能用全图均差吞掉单像素实质变化")
        let lowBudget = LongScreenshotService(screenshotService: SystemScreenshotService(), byteLimit: 100)
        XCTAssertThrowsError(try lowBudget.hasNoNewContent(frame, noise), "无新增也不能吞掉预算失败")
    }

    @MainActor
    func testRealFailureNoticesAreShortAndNeverClaimCompletePage() {
        for error: Error in [LongScreenshotError.untrustedOverlap, LongScreenshotError.memoryLimit,
                            ScreenCaptureError.screenRecordingPermissionRequired, CocoaError(.fileWriteOutOfSpace)] {
            let notice = AppCoordinator.longCaptureFailureNotice(error, hasImage: true)
            XCTAssertTrue(notice.contains("请检查尾部"))
            XCTAssertFalse(notice.contains("完整页面"))
            XCTAssertLessThan(notice.count, 45)
            XCTAssertTrue(AppCoordinator.longCaptureFailureNotice(error, hasImage: false).contains("未生成图片"))
        }
    }

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
        XCTAssertEqual(LongScreenshotService.scrollStep(height: 100), 15)
        XCTAssertEqual(LongScreenshotService.scrollStep(height: .nan), 1)
        XCTAssertEqual(LongScreenshotService.scrollStep(height: 1200), 120)
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
                if !didScroll { didScroll = true; scrolled.fulfill() }
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

    func testFixedHeaderFooterAndLocalDynamicContentTolerated() throws {
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
        XCTAssertEqual(try service.validatedOverlap(previous: changed(first, y: 0), current: changed(second, y: 0)), 40)
        XCTAssertEqual(try service.validatedOverlap(previous: changed(first, y: 72), current: changed(second, y: 72)), 40)
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
