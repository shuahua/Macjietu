import AppKit
import XCTest
@testable import 截图Free

@MainActor
final class AnnotationToolOptionsTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func assertGlassPanel(_ panel: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(panel.isOpaque, file: file, line: line)
        XCTAssertEqual(panel.backgroundColor.alphaComponent, 0, file: file, line: line)
        XCTAssertTrue(panel.styleMask.contains(.borderless), file: file, line: line)
        XCTAssertTrue(panel.hasShadow, file: file, line: line)
        let clip = try XCTUnwrap(panel.contentView)
        let glass = try XCTUnwrap(clip as? GlassView)
        let effect = glass.effectView
        // 功能玻璃需要非零 backing；窗口外透明区域仍保持零 alpha。
        XCTAssertEqual(clip.layer?.backgroundColor?.alpha, GlassView.interactionBackingOpacity, file: file, line: line)
        for view in [clip, effect] {
            XCTAssertEqual(view.layer?.cornerRadius, 14, file: file, line: line)
            if glass.backend != .native { XCTAssertEqual(view.layer?.masksToBounds, true, file: file, line: line) }
            XCTAssertEqual(view.layer?.borderWidth, 0, file: file, line: line)
            XCTAssertNil(view.layer?.borderColor, file: file, line: line)
        }
        XCTAssertEqual(effect.frame, clip.bounds, file: file, line: line)
        XCTAssertEqual(effect.material, .hudWindow, file: file, line: line)
        XCTAssertEqual(effect.blendingMode, .behindWindow, file: file, line: line)
        XCTAssertEqual(effect.state, glass.reducesTransparency ? .inactive : .active, file: file, line: line)
        XCTAssertEqual(glass.tintOpacity, glass.reducesTransparency ? 1 : GlassView.normalTintOpacity)
    }

    func testGlassPanelResizesWithoutUncoveredEdgesInBothAppearances() throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for size in [CGSize(width: 336, height: 86), CGSize(width: 420, height: 126)] {
                let panel = AnnotationEditorController.makeOptionsPanel(size: size)
                panel.appearance = NSAppearance(named: appearance)
                try assertGlassPanel(panel)
                panel.setContentSize(CGSize(width: size.width + 40, height: size.height + 20))
                panel.contentView?.layoutSubtreeIfNeeded()
                try assertGlassPanel(panel)
            }
        }
    }

    func testAllToolbarEntriesShareStyleControlsAndCloseOldPanels() throws {
        _ = NSApplication.shared
        for zoom in [false, true] {
            let controller = AnnotationEditorController(image: NSImage(size: CGSize(width: 400, height: 300)), allowsZoom: zoom)
            controller.show()
            defer { _ = controller.perform(NSSelectorFromString("closeWindow")) }
            let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "截图编辑" })
            let views = descendants(try XCTUnwrap(window.contentView))
            let canvas = try XCTUnwrap(views.compactMap { $0 as? AnnotationCanvasView }.first)
            let segments = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }.first)
            let popup = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first)
            func panel() throws -> NSWindow { try XCTUnwrap(window.childWindows?.first) }
            func selectSegment(_ index: Int) {
                segments.selectedSegment = index
                segments.sendAction(segments.action, to: segments.target)
            }
            for (index, tool) in [AnnotationTool.rectangle, .oval, .line, .arrow].enumerated() {
                selectSegment(0)
                let old = try panel()
                popup.selectItem(at: index)
                popup.sendAction(popup.action, to: popup.target)
                XCTAssertEqual(canvas.tool, tool)
                XCTAssertEqual(segments.selectedSegment, -1)
                XCTAssertFalse(old.isVisible)
                XCTAssertNil(old.contentView)
                let current = try panel()
                try assertGlassPanel(current)
                XCTAssertEqual(current.frame.size, CGSize(width: 336, height: 86))
                let controls = descendants(try XCTUnwrap(current.contentView))
                let slider = try XCTUnwrap(controls.compactMap { $0 as? NSSlider }.first)
                slider.doubleValue = 9
                slider.sendAction(slider.action, to: slider.target)
                XCTAssertEqual(canvas.strokeWidth, 9)
                let color = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.tag == 3 })
                color.performClick(nil)
                XCTAssertEqual(canvas.strokeColor, .systemBlue)
                popup.sendAction(popup.action, to: popup.target)
                XCTAssertEqual(canvas.tool, .none)
                XCTAssertTrue(window.childWindows?.isEmpty ?? true)
                XCTAssertFalse(current.isVisible)
            }
            for index in [0, 3, 1, 2] {
                selectSegment(index)
                XCTAssertEqual(window.childWindows?.count ?? 0, [0, 3].contains(index) ? 1 : 0)
                if index == 3 {
                    try assertGlassPanel(try panel())
                    let controls = descendants(try XCTUnwrap(try panel().contentView))
                    XCTAssertEqual(controls.compactMap { $0 as? NSSlider }.first?.tag, 1)
                }
                selectSegment(index)
                XCTAssertEqual(canvas.tool, .none)
                XCTAssertTrue(window.childWindows?.isEmpty ?? true)
            }
            // 直接 action 入口也必须支持切换和再次点击关闭。
            for name in ["selectRectangle", "selectOval", "selectLine", "selectArrow"] {
                _ = controller.perform(NSSelectorFromString(name))
                XCTAssertEqual(window.childWindows?.count, 1)
                _ = controller.perform(NSSelectorFromString(name))
                XCTAssertEqual(canvas.tool, .none)
                XCTAssertTrue(window.childWindows?.isEmpty ?? true)
            }
        }
    }
}
