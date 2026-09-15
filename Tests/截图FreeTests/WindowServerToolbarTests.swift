import AppKit
import QuartzCore
import XCTest
@testable import 截图Free

/// 不投递全局事件、不申请权限。查询真实可见窗口，而非伪造 windowNumber 的 sendEvent。
@MainActor
final class WindowServerToolbarTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settle(_ windows: [NSWindow]) {
        for window in windows { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        CATransaction.flush()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
    }

    func testVisibleWindowServerProbe() throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 200, y: 200, width: 700, height: 240)
        let probe = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        probe.title = "Toolbar regression background probe"
        probe.isReleasedWhenClosed = false
        probe.backgroundColor = .white
        probe.level = .floating
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let glass = GlassView(frame: NSRect(x: 32, y: 32, width: 560, height: 62))
        glass.castsSoftShadow = true
        root.addSubview(glass)
        let front = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        front.title = "Toolbar regression transparent front"
        front.isReleasedWhenClosed = false
        front.level = .floating
        front.hasShadow = false
        GlassView.prepareWindow(front)
        front.contentView = root
        defer { front.orderOut(nil); probe.orderOut(nil) }
        probe.orderFrontRegardless()
        front.order(.above, relativeTo: probe.windowNumber)
        settle([probe, front])
        XCTAssertTrue(front.isVisible)
        let ids = [NSNumber(value: front.windowNumber), NSNumber(value: probe.windowNumber)] as CFArray
        print("PROBE descriptions", CGWindowListCreateDescriptionFromArray(ids) as Any)
        print("PROBE flags", front.ignoresMouseEvents, front.isOpaque, front.alphaValue, glass.backend, root.frame, glass.frame, glass.controlsHost.frame)
        for point in [NSPoint(x: 100, y: 60), NSPoint(x: 10, y: 150)] {
            let screen = front.convertPoint(toScreen: point)
            print("PROBE query", point, NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0), "front", front.windowNumber, "back", probe.windowNumber)
            XCTAssertEqual(NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0), point.x == 100 ? front.windowNumber : probe.windowNumber)
        }
        // 负对照：完全相同的窗口/材质/坐标，只移除 backing，重现上轮漏检。
        if glass.backend == .native {
            glass.layer?.backgroundColor = NSColor.clear.cgColor
            settle([front])
            XCTAssertNotNil(root.hitTest(NSPoint(x: 100, y: 60)))
            XCTAssertEqual(NSWindow.windowNumber(at: front.convertPoint(toScreen: NSPoint(x: 100, y: 60)), belowWindowWithWindowNumber: 0), probe.windowNumber)
            glass.layer?.backgroundColor = NSColor.black.withAlphaComponent(GlassView.interactionBackingOpacity).cgColor
            settle([front])
            XCTAssertEqual(NSWindow.windowNumber(at: front.convertPoint(toScreen: NSPoint(x: 100, y: 60)), belowWindowWithWindowNumber: 0), front.windowNumber)
        }
    }

    /// 查询功能区域的稠密网格、控件和每个分段；下层只放本测试拥有的 probe。
    private func verify(_ window: NSWindow, blank: NSPoint?) throws {
        let root = try XCTUnwrap(window.contentView)
        let glass = try XCTUnwrap(descendants(root).compactMap { $0 as? GlassView }.first)
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        let probe = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        probe.title = "Toolbar owned background \(UUID())"
        probe.isReleasedWhenClosed = false
        probe.backgroundColor = .white
        probe.level = window.level
        defer { window.orderOut(nil); probe.orderOut(nil) }
        probe.orderFrontRegardless()
        window.order(.above, relativeTo: probe.windowNumber)
        for mode in [0, 1, 2, 0] {
            glass.forceFallback = mode == 1
            glass.updateAccessibility(reduceTransparency: mode == 2)
            settle([probe, window])
            XCTAssertTrue(window.isVisible)
            XCTAssertFalse(window.ignoresMouseEvents)
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.alphaValue, 1)
            XCTAssertEqual(glass.mouseDownCanMoveWindow, window is RecordingPreviewWindow || window.title == "截图Free 设置")
            XCTAssertFalse(glass.controlsHost.frame.isEmpty)
            let number = window.windowNumber
            func query(_ local: NSPoint, in view: NSView, expected: Int) {
                let p = window.convertPoint(toScreen: view.convert(local, to: nil))
                XCTAssertTrue(probe.frame.contains(p))
                XCTAssertEqual(NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0), expected,
                               "\(window.title) mode=\(mode) local=\(local)")
            }
            for x in stride(from: CGFloat(16), through: glass.bounds.width - 16, by: 12) {
                for y in stride(from: CGFloat(16), through: glass.bounds.height - 16, by: 10) {
                    query(NSPoint(x: x, y: y), in: glass, expected: number)
                }
            }
            for control in descendants(glass.controlsHost).compactMap({ $0 as? NSControl }) {
                let p = NSPoint(x: control.bounds.midX, y: control.bounds.midY)
                query(p, in: control, expected: number)
                if control.action != nil {
                    let hit = root.hitTest(control.convert(p, to: root.superview))
                    XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true)
                }
                if let segments = control as? NSSegmentedControl {
                    for index in 0..<segments.segmentCount {
                        query(NSPoint(x: segments.bounds.width * (CGFloat(index) + 0.5) / CGFloat(segments.segmentCount), y: p.y), in: segments, expected: number)
                    }
                }
            }
            if let blank { query(blank, in: root, expected: probe.windowNumber) }
            print("SERVER verified title=\(window.title) id=\(number) backend=\(glass.backend) style=\(window.styleMask.rawValue) level=\(window.level.rawValue) root=\(root.frame) glass=\(glass.frame) host=\(glass.controlsHost.frame)")
        }
    }

    func testProductionEditorsParametersAndRecordingPanels() throws {
        _ = NSApplication.shared
        for zoom in [false, true] {
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            let controller = AnnotationEditorController(image: NSImage(size: NSSize(width: 400, height: 300)), allowsZoom: zoom)
            controller.show()
            defer { _ = controller.perform(NSSelectorFromString("closeWindow")) }
            let window = try XCTUnwrap(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.title == "截图编辑" })
            try verify(window, blank: NSPoint(x: 4, y: 4))
            // 参数生成经生产 action；并非宣称系统鼠标打开 popover 已验收。
            _ = controller.perform(NSSelectorFromString("selectText"))
            let panel = try XCTUnwrap(window.childWindows?.first { $0.title == "标注参数" })
            try verify(panel, blank: nil)
        }
        let options = RecordingOptionsWindowController(selectionRect: NSRect(x: 100, y: 100, width: 400, height: 300))
        defer { options.close() }
        try verify(options.window, blank: NSPoint(x: 4, y: 4))
        let recording = RecordingControlWindowController(selectionRect: .zero, audioSource: .none, quality: .high)
        defer { recording.close() }
        try verify(recording.window, blank: NSPoint(x: 4, y: 4))
    }

    func testRecordingPreviewToolbarAndTransparentMargins() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-probe-\(UUID()).mov")
        try Data("自建探针".utf8).write(to: url)
        let controller = RecordingPreviewWindowController(url: url)
        defer { controller.window.close() }
        XCTAssertTrue(controller.window is RecordingPreviewWindow)
        XCTAssertEqual(controller.window.title, "")
        try verify(controller.window, blank: NSPoint(x: 4, y: 4))
    }

    func testSettingsAllCategoriesKeepWindowServerHitAcrossBackends() throws {
        _ = NSApplication.shared
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = SettingsWindowController(settingsStore: SettingsStore(fileURL: temporaryURL().appendingPathComponent("settings.json")))
        let window = controller.makeWindow()
        XCTAssertFalse(before.contains(ObjectIdentifier(window)))
        XCTAssertEqual(window.title, "截图Free 设置")
        // 测试进程不是前台应用；普通层级窗口可能被后台排序压在 probe 下。
        // 只提升本测试窗口，不改生产层级、不激活或操控用户应用。
        let originalLevel = window.level
        window.level = .floating
        defer { window.level = originalLevel }
        defer { window.close() }
        for category in SettingsWindowController.Category.allCases {
            controller.selectCategory(category)
            try verify(window, blank: nil)
        }
    }
}
