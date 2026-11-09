import AppKit
import XCTest
@testable import 截图Free

@MainActor
final class AnnotationAutoCopyTests: XCTestCase {
    final class Board: ImagePasteboard {
        var changeCount = 0
        var writes = [Data]()
        func replacePNG(_ data: Data) -> Bool { writes.append(data); changeCount += 1; return true }
    }
    private let a = UUID(), b = UUID()
    private func request(_ service: ClipboardService, _ owner: UUID, _ revision: UInt64 = 0,
                         automatic: Bool = true) throws -> ClipboardService.Request {
        try XCTUnwrap(service.request(owner: owner, revision: revision, automatic: automatic) { nil })
    }

    func testInitialRevisionInterleavingAndLateResults() throws {
        let board = Board()
        let center = ClipboardService(pasteboard: board); center.automaticEnabled = true
        let first = try request(center, a)
        center.complete(first, data: Data([1]))
        let oldA = try request(center, a, 1)
        let newB = try request(center, b, 1)
        center.complete(newB, data: Data([3]))
        center.complete(oldA, data: Data([2]))
        XCTAssertEqual(board.writes, [Data([1]), Data([3])])
        let activeA = try request(center, a, 2)
        center.complete(activeA, data: Data([4]))
        XCTAssertEqual(center.clipboardOwner, a)
        XCTAssertEqual(board.writes.last, Data([4]))
    }

    func testExternalChangeFailureCloseSettingsAndManualPriority() throws {
        let board = Board()
        let service = ClipboardService(pasteboard: board); service.automaticEnabled = true
        let old = try request(service, a)
        board.changeCount += 1
        service.complete(old, data: Data([1]))
        XCTAssertTrue(board.writes.isEmpty)
        let failed = try request(service, a, 1)
        service.complete(failed, data: nil)
        XCTAssertEqual(board.changeCount, 1)
        let other = try request(service, b)
        service.close(owner: a)
        service.complete(other, data: Data([2]))
        let closed = try request(service, a, 2)
        service.close(owner: a)
        service.complete(closed, data: Data([3]))
        let disabled = try request(service, b, 2)
        service.automaticEnabled = false
        service.complete(disabled, data: Data([4]))
        XCTAssertEqual(board.writes, [Data([2])])
        XCTAssertNil(service.request(owner: a, revision: 4) { nil })
        service.automaticEnabled = true
        let auto = try request(service, a, 5)
        let manual = try request(service, b, automatic: false)
        service.automaticEnabled = false
        service.complete(manual, data: Data([6]))
        service.complete(auto, data: Data([5]))
        XCTAssertEqual(board.writes, [Data([2]), Data([6])])
    }

    func testDebounceCapturesOnlyLatestAndEncodesOffMain() async throws {
        let board = Board()
        let service = ClipboardService(pasteboard: board, delay: 0.02); service.automaticEnabled = true
        var snapshots = 0
        let encoded = expectation(description: "合并后的后台编码")
        for revision in 0..<200 {
            service.request(owner: a, revision: UInt64(revision)) {
                XCTAssertTrue(Thread.isMainThread)
                snapshots += 1
                return {
                    XCTAssertFalse(Thread.isMainThread)
                    encoded.fulfill()
                    return Data([7])
                }
            }
        }
        await fulfillment(of: [encoded], timeout: 5)
        let written = expectation(description: "主线程写入")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { written.fulfill() }
        await fulfillment(of: [written], timeout: 5)
        XCTAssertEqual(snapshots, 1)
        XCTAssertEqual(board.writes, [Data([7])])
    }

    func testActualUniquePasteboardAndEncodingFailurePreserveContents() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("外部内容", forType: .string)
        let service = ClipboardService(pasteboard: board); service.automaticEnabled = true
        let failed = try request(service, a)
        let count = board.changeCount
        service.complete(failed, data: nil)
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(board.string(forType: .string), "外部内容")
        let canvas = fixture()
        let png = try XCTUnwrap(canvas.automaticCopySnapshot())()
        service.complete(try request(service, a, 1), data: png)
        XCTAssertTrue(board.types?.contains(.png) == true)
        XCTAssertNil(board.string(forType: .string), "旧内容已替换；系统可自动提供 TIFF 等兼容类型")
        XCTAssertEqual(board.data(forType: .png), png)
        service.close(owner: a)
        XCTAssertEqual(board.data(forType: .png), png)
    }

    private func fixture() -> AnnotationCanvasView {
        _ = NSApplication.shared
        let image = NSImage(size: CGSize(width: 200, height: 150))
        image.lockFocus(); NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 200, height: 150).fill(); image.unlockFocus()
        return AnnotationCanvasView(frame: CGRect(x: 0, y: 0, width: 200, height: 150), image: image)
    }

    func testCanvasCompletedTransactionsUndoRedoTextAndNoOp() throws {
        let canvas = fixture()
        var revisions = [UInt64]()
        canvas.onContentChange = { revisions.append($0) }
        canvas.tool = .pen; canvas.tool = .rectangle
        canvas.clear()
        XCTAssertTrue(revisions.isEmpty)
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: x), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, 20))
        for x in 21...90 { canvas.mouseDragged(with: try event(.leftMouseDragged, CGFloat(x))) }
        XCTAssertTrue(revisions.isEmpty)
        canvas.mouseUp(with: try event(.leftMouseUp, 90))
        XCTAssertEqual(revisions.count, 1)
        canvas.undoAnnotation(); canvas.redoAnnotation(); canvas.clear()
        XCTAssertEqual(revisions.count, 4)
        canvas.tool = .text; canvas.beginText(at: CGPoint(x: 20, y: 120))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.string = "测试"; canvas.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(revisions.count, 5)
        _ = try XCTUnwrap(canvas.automaticCopySnapshot())()
        XCTAssertTrue(editor.superview === canvas, "自动快照不得结束文字编辑")
        canvas.commitTextEditing()
        XCTAssertEqual(revisions.count, 5, "同样内容提交不重复发请求")
        canvas.selectText(at: 0); canvas.textUnderline = true
        XCTAssertEqual(revisions.count, 6)
        canvas.dispose()
    }

    func testMarkedTextSnapshotDoesNotCommitComposition() throws {
        let canvas = fixture(); canvas.tool = .text; canvas.beginText(at: CGPoint(x: 20, y: 120))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.setMarkedText("组合", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let range = editor.markedRange()
        XCTAssertNil(canvas.automaticCopySnapshot())
        XCTAssertTrue(editor.hasMarkedText()); XCTAssertEqual(editor.markedRange(), range)
    }

    func testSavedSettingImmediatelyCancelsWithoutClearing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        let board = Board()
        let center = ClipboardService(pasteboard: board)
        center.observeSettings(store)
        var settings = AppSettings.defaults; settings.autoCopyAfterCapture = true
        try store.save(settings)
        XCTAssertTrue(center.automaticEnabled)
        let pending = try request(center, a)
        settings.autoCopyAfterCapture = false
        try store.save(settings)
        XCTAssertNil(center.currentRequest)
        center.complete(pending, data: Data([1]))
        XCTAssertEqual(board.changeCount, 0)
    }

    func testRunningRendererCannotOverwriteLaterExternalCopy() async throws {
        let board = Board(), center = ClipboardService(pasteboard: board, delay: 0)
        center.automaticEnabled = true
        let started = expectation(description: "编码开始")
        let returned = expectation(description: "编码返回")
        let gate = DispatchSemaphore(value: 0)
        center.request(owner: a, revision: 1) {
            return {
                started.fulfill()
                _ = gate.wait(timeout: .now() + 5)
                returned.fulfill()
                return Data([9])
            }
        }
        await fulfillment(of: [started], timeout: 5)
        board.changeCount += 1
        gate.signal()
        await fulfillment(of: [returned], timeout: 5)
        let drained = expectation(description: "回调处理完毕")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertTrue(board.writes.isEmpty)
        XCTAssertNil(center.currentRequest)
    }

    func testLargeImageBurstSnapshotsOnceAndWritesRealPNG() async throws {
        let board = Board(), service = ClipboardService(pasteboard: board, delay: 0.02)
        service.automaticEnabled = true
        let context = try XCTUnwrap(CGContext(data: nil, width: 2048, height: 4096, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 1024, height: 2048))
        let canvas = AnnotationCanvasView(frame: CGRect(x: 0, y: 0, width: 256, height: 512), image: image)
        var snapshots = 0
        let done = expectation(description: "大图后台编码")
        for revision in 0..<100 {
            service.request(owner: a, revision: UInt64(revision)) {
                snapshots += 1
                guard let render = canvas.automaticCopySnapshot() else { return nil }
                return {
                    let data = try render()
                    done.fulfill()
                    return data
                }
            }
        }
        await fulfillment(of: [done], timeout: 15)
        let drain = expectation(description: "写入完成")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drain.fulfill() }
        await fulfillment(of: [drain], timeout: 5)
        XCTAssertEqual(snapshots, 1); XCTAssertEqual(board.writes.count, 1)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(board.writes.first)))
        XCTAssertEqual(bitmap.pixelsWide, 2048); XCTAssertEqual(bitmap.pixelsHigh, 4096)
    }
}
