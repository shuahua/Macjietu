import AppKit
import XCTest
@testable import 截图Free

@MainActor
final class RecordingToolbarInteractionTests: XCTestCase {
    private let selection = NSRect(x: 420, y: 310, width: 500, height: 300)
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func configure(_ window: NSWindow, mode: Int) throws {
        _ = NSApplication.shared
        window.setFrameOrigin(NSPoint(x: 217, y: 163))
        let root = try XCTUnwrap(window.contentView)
        for glass in descendants(root).compactMap({ $0 as? GlassView }) {
            glass.forceFallback = mode == 1
            glass.updateAccessibility(reduceTransparency: mode == 2)
            root.layoutSubtreeIfNeeded()
            XCTAssertFalse(glass.controlsHost.frame.isEmpty)
            XCTAssertTrue(root.bounds.contains(glass.frame.insetBy(dx: -26, dy: -26)))
            XCTAssertFalse(glass.layer?.masksToBounds ?? true)
            XCTAssertEqual(glass.layer?.shadowOpacity ?? 0, glass.backend == .native ? 0 : 0.12, accuracy: 0.001)
        }
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.isMovableByWindowBackground)
        if window is RecordingToolbarPanel {
            XCTAssertFalse(window.canBecomeMain)
            XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
            XCTAssertFalse(window.hasShadow)
        } else { XCTAssertFalse(window.styleMask.contains(.titled)) }
    }

    private func button(_ title: String, in window: NSWindow) throws -> NSButton {
        try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? NSButton }.first { $0.title == title } })
    }

    /// 真窗口根命中：先变换到屏幕，再转换回根视图父坐标；覆盖非零窗口 origin 和原生私有包装层。
    @discardableResult
    private func hit(_ control: NSControl) throws -> NSView {
        let window = try XCTUnwrap(control.window)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(window.frame.origin, .zero)
        let center = NSPoint(x: control.bounds.midX, y: control.bounds.midY)
        let screenPoint = window.convertPoint(toScreen: control.convert(center, to: nil))
        let basePoint = window.convertPoint(fromScreen: screenPoint)
        let point = root.superview?.convert(basePoint, from: nil) ?? basePoint
        let result = try XCTUnwrap(root.hitTest(point))
        XCTAssertTrue(result === control || result.isDescendant(of: control), "错误命中：\(result)")
        XCTAssertTrue(control.isEnabled)
        return result
    }

    private func click(_ control: NSButton) throws {
        let target = try hit(control)
        let window = try XCTUnwrap(control.window)
        XCTAssertNotNil(control.target)
        XCTAssertNotNil(control.action)
        let location = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: time + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        target.mouseDown(with: down)
    }

    func testOptionsAudioQualityAndStartNativeTrackingAcrossBackends() throws {
        _ = NSApplication.shared
        for mode in 0..<3 {
            for audio in RecordingAudioSource.allCases {
                for quality in RecordingQuality.allCases {
                    let controller = RecordingOptionsWindowController(selectionRect: selection)
                    defer { controller.close() }
                    try configure(controller.window, mode: mode)
                    let popups = descendants(try XCTUnwrap(controller.window.contentView)).compactMap { $0 as? NSPopUpButton }
                    XCTAssertEqual(popups.count, 2)
                    XCTAssertEqual(popups[0].titleOfSelectedItem, RecordingAudioSource.none.title)
                    XCTAssertEqual(popups[1].titleOfSelectedItem, RecordingQuality.high.title)
                    for popup in popups { try hit(popup) }
                    // 选项按开始时读取，不需要 target/action；不宣称测试了系统菜单实机鼠标选择。
                    popups[0].selectItem(withTitle: audio.title)
                    popups[1].selectItem(withTitle: quality.title)
                    var calls = 0
                    controller.onStart = { a, q in
                        XCTAssertEqual(a, audio); XCTAssertEqual(q, quality); calls += 1
                    }
                    controller.onCancel = { XCTFail("开始不能发送取消") }
                    let start = try button("开始", in: controller.window)
                    XCTAssertEqual(start.keyEquivalent, "\r")
                    try click(start)
                    XCTAssertEqual(calls, 1)
                    XCTAssertFalse(start.isEnabled)
                    XCTAssertNil(controller.onStart); XCTAssertNil(controller.onCancel)
                    _ = start.sendAction(try XCTUnwrap(start.action), to: start.target)
                    XCTAssertEqual(calls, 1)
                }
            }
        }
    }

    func testCancelAndClosedOptionsCannotStart() throws {
        _ = NSApplication.shared
        for mode in 0..<3 {
            let controller = RecordingOptionsWindowController(selectionRect: selection)
            try configure(controller.window, mode: mode)
            let start = try button("开始", in: controller.window)
            let cancel = try button("取消", in: controller.window)
            var calls = 0
            controller.onStart = { _, _ in XCTFail("取消不能开始录制") }
            controller.onCancel = { calls += 1 }
            XCTAssertEqual(cancel.keyEquivalent, "\u{1b}")
            try click(cancel)
            XCTAssertEqual(calls, 1)
            controller.close()
            _ = start.sendAction(try XCTUnwrap(start.action), to: start.target)
            XCTAssertNil(controller.window.contentView)
            XCTAssertNil(controller.onStart); XCTAssertNil(controller.onCancel)
        }
    }

    func testCompletionStopsOnlyItsControllerOnceAndClearsCallback() throws {
        _ = NSApplication.shared
        for mode in 0..<3 {
            let old = RecordingControlWindowController(selectionRect: selection, audioSource: .both, quality: .original)
            let current = RecordingControlWindowController(selectionRect: selection, audioSource: .none, quality: .high)
            defer { old.close(); current.close() }
            try configure(old.window, mode: mode)
            try configure(current.window, mode: mode)
            var oldCalls = 0, currentCalls = 0
            old.onStop = { oldCalls += 1 }
            current.onStop = { currentCalls += 1 }
            let stop = try button("完成", in: old.window)
            XCTAssertTrue(stop.target === old)
            XCTAssertEqual(stop.state, .off)
            try click(stop)
            XCTAssertEqual(oldCalls, 1); XCTAssertEqual(currentCalls, 0)
            XCTAssertFalse(stop.isEnabled); XCTAssertNil(old.onStop)
            _ = stop.sendAction(try XCTUnwrap(stop.action), to: stop.target)
            old.close()
            _ = stop.sendAction(try XCTUnwrap(stop.action), to: stop.target)
            XCTAssertEqual(oldCalls, 1); XCTAssertEqual(currentCalls, 0)
            try click(button("完成", in: current.window))
            XCTAssertEqual(currentCalls, 1)
        }
    }

    func testPreviewSaveCancelSaveAndCloseNativeTracking() throws {
        _ = NSApplication.shared
        for mode in 0..<3 {
            for save in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let source = directory.appendingPathComponent("source.mov")
                let destination = directory.appendingPathComponent("export.mov")
                let bytes = Data("测试自建文件，不录屏".utf8)
                try bytes.write(to: source)
                var chooseCount = 0, closeCount = 0, cancelled = true
                let controller = RecordingPreviewWindowController(url: source, chooseDestination: {
                    chooseCount += 1
                    return cancelled ? nil : destination
                })
                defer { controller.window.close() }
                controller.onClose = { closeCount += 1 }
                try configure(controller.window, mode: mode)
                controller.window.setContentSize(NSSize(width: 820, height: 600))
                try configure(controller.window, mode: mode)
                let saveButton = try button("保存导出", in: controller.window)
                let closeButton = try button("关闭", in: controller.window)
                try hit(closeButton)
                try click(saveButton)
                XCTAssertEqual(chooseCount, 1); XCTAssertEqual(closeCount, 0)
                XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
                if save {
                    cancelled = false
                    try click(saveButton)
                    XCTAssertEqual(try Data(contentsOf: destination), bytes)
                } else { try click(closeButton) }
                XCTAssertEqual(closeCount, 1)
                XCTAssertNil(controller.onClose)
                XCTAssertNil(controller.window.contentView)
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
                _ = saveButton.sendAction(try XCTUnwrap(saveButton.action), to: saveButton.target)
                XCTAssertEqual(chooseCount, save ? 2 : 1)
                controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
                XCTAssertEqual(closeCount, 1)
            }
        }
    }
}
