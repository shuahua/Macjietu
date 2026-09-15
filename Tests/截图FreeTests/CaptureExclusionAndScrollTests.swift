import AppKit
import XCTest
@testable import 截图Free

final class CaptureExclusionAndScrollTests: XCTestCase {
    func testExclusionUsesBothStableWindowIDAndOwnerPreservingOrder() throws {
        let windows: [[String: Any]] = [(1, 10), (2, 20), (3, 10), (4, 30)].map {
            [kCGWindowNumber as String: UInt32($0.0), kCGWindowOwnerPID as String: Int32($0.1)]
        }
        XCTAssertEqual(try ScreenCaptureService.includedWindowIDs(windows, excluding: [1, 2], ownerPID: 10), [2, 3, 4])
        XCTAssertThrowsError(try ScreenCaptureService.includedWindowIDs([[:]], excluding: [1], ownerPID: 10))
    }

    func testExclusionFailureNeverFallsBackToDirtyDisplay() {
        let service = ScreenCaptureService(hasScreenAccess: { true }, currentDisplays: {
            [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]
        }, captureDisplay: { _ in XCTFail("不能捕获包含浮层的整屏"); return nil },
        captureQuartzRect: { _ in XCTFail("不能静默回退"); return nil },
        windowList: { [[kCGWindowNumber as String: UInt32(2), kCGWindowOwnerPID as String: Int32(-1)]] },
        captureWindows: { _, ids in XCTAssertEqual(ids, [2]); return nil })
        XCTAssertThrowsError(try service.captureCGImage(rect: CGRect(x: 0, y: 0, width: 50, height: 50), excludingWindowIDs: [1]))
    }

    @MainActor
    func testSmoothEventsHaveBoundedDeltaYieldAndCancelMidBatch() async throws {
        for delta: Int32 in [-120, -17, 0, 1, 119] {
            let segments = SmoothScroll.segments(delta: delta)
            XCTAssertEqual(segments.reduce(0, +), delta)
            XCTAssertTrue(segments.allSatisfy { abs($0) <= 6 })
        }
        var times: [Date] = []
        let first = expectation(description: "首个平滑事件")
        let task = Task { @MainActor in
            try await SmoothScroll.run(delta: -120) { _ in
                times.append(Date())
                if times.count == 1 { first.fulfill() }
            }
        }
        await fulfillment(of: [first], timeout: 1)
        task.cancel()
        do { try await task.value; XCTFail("取消必须传播") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(times.count, 20)
        var complete: [Date] = []
        try await SmoothScroll.run(delta: 18) { _ in complete.append(Date()) }
        XCTAssertEqual(complete.count, 3)
        XCTAssertGreaterThanOrEqual(complete.last!.timeIntervalSince(complete.first!), 0.025)
    }

    @MainActor
    func testPreviewUpdateKeepsWindowsVisibleAndIDsStable() throws {
        _ = NSApplication.shared
        let overlay = LongScreenshotProgressOverlayController(selectionRect: CGRect(x: 100, y: 100, width: 80, height: 100))
        overlay.show()
        defer { overlay.close() }
        let ids = overlay.captureWindowIDs
        XCTAssertEqual(ids.count, 2)
        let visible = NSApp.windows.filter { ids.contains(CGWindowID($0.windowNumber)) && $0.isVisible }
        XCTAssertFalse(visible.isEmpty)
        overlay.updatePreview(image: NSImage(size: CGSize(width: 80, height: 120)), frameCount: 2)
        XCTAssertEqual(overlay.captureWindowIDs, ids)
        XCTAssertTrue(visible.allSatisfy(\.isVisible))
    }
}
