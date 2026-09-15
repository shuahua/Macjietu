import AppKit
import XCTest
@testable import 截图Free

@MainActor
final class ToolbarInteractionShadowTests: XCTestCase {
    @MainActor private final class ActionProbe: NSObject {
        var count = 0
        @objc func invoke(_ sender: NSButton) {
            count += 1
            XCTAssertEqual(sender.state, .off)
            XCTAssertFalse(sender.isHighlighted)
        }
    }

    func testFourMomentaryActionsReleaseCancelRepeatAndKeyboard() throws {
        for mode in 0..<3 {
            let (controller, window, glass, canvas) = try editor(zoom: false)
            defer { _ = controller.perform(NSSelectorFromString("closeWindow")) }
            glass.forceFallback = mode == 1
            glass.updateAccessibility(reduceTransparency: mode == 2)
            let controls = descendants(glass)
            let segments = try XCTUnwrap(controls.compactMap { $0 as? NSSegmentedControl }.first)
            segments.selectedSegment = 3
            try dispatch(segments)
            let buttons = controls.compactMap { $0 as? GlassButton }
            XCTAssertFalse(try XCTUnwrap(buttons.first { $0.toolTip == "关闭" }).usesMomentaryActionSurface)
            for title in ["清空", "复制", "保存", "贴图"] {
                let button = try XCTUnwrap(buttons.first { $0.toolTip == title })
                let cell = try XCTUnwrap(button.cell as? NSButtonCell)
                XCTAssertTrue(button.usesMomentaryActionSurface)
                XCTAssertEqual(cell.highlightsBy, [.pushInCellMask])
                XCTAssertTrue(cell.showsStateBy.isEmpty)
                let probe = ActionProbe()
                button.target = probe
                button.action = #selector(ActionProbe.invoke(_:))
                button.setHovered(true)
                _ = window.makeFirstResponder(button)
                func assertIdle() {
                    XCTAssertEqual(button.state, .off)
                    XCTAssertEqual(cell.state, .off)
                    XCTAssertFalse(cell.isHighlighted)
                    XCTAssertEqual(button.feedbackLevel, 0)
                    XCTAssertFalse(button.hasFeedbackAnimation)
                    XCTAssertEqual(button.layer?.sublayers?.first { $0.name == "glassFeedbackSurface" }?.opacity, 0)
                    XCTAssertEqual(button.alphaValue, 1)
                }
                assertIdle()
                for cancel in [false, true, false, false] {
                    let before = probe.count
                    let target = try hit(button)
                    let p = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                    }
                    let end = cancel ? NSPoint(x: p.x, y: p.y + 90) : p
                    let down = event(.leftMouseDown, p)
                    let drag = event(.leftMouseDragged, end)
                    let up = event(.leftMouseUp, end)
                    var observedPress = false
                    let feedback = try XCTUnwrap(button.layer?.sublayers?.first { $0.name == "glassFeedbackSurface" })
                    let observation = feedback.observe(\.opacity, options: [.new]) { _, change in
                        MainActor.assumeIsolated {
                            if change.newValue == 0.22 { observedPress = true }
                        }
                    }
                    NSApp.postEvent(up, atStart: true)
                    if cancel { NSApp.postEvent(drag, atStart: true) }
                    target.mouseDown(with: down)
                    observation.invalidate()
                    XCTAssertTrue(observedPress)
                    XCTAssertEqual(probe.count, before + (cancel ? 0 : 1))
                    assertIdle()
                }
                let before = probe.count
                button.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)))
                XCTAssertEqual(probe.count, before + 1)
                assertIdle()
                button.performClick(nil)
                XCTAssertEqual(probe.count, before + 2)
                assertIdle()
                XCTAssertEqual(segments.selectedSegment, 3)
                XCTAssertEqual(canvas.tool, .text)
            }
            let shapes = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first)
            shapes.selectItem(at: 2)
            try dispatch(shapes)
            for button in buttons where button.usesMomentaryActionSurface { button.performClick(nil) }
            XCTAssertEqual(canvas.tool, .line)
            XCTAssertEqual(shapes.layer?.borderWidth, 2)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    /// 从窗口根视图开始；每层均传入该层父坐标，不能以 performClick 代替命中。
    @discardableResult
    private func hit(_ control: NSView, local: NSPoint? = nil,
                     file: StaticString = #filePath, line: UInt = #line) throws -> NSView {
        let root = try XCTUnwrap(control.window?.contentView, file: file, line: line)
        root.layoutSubtreeIfNeeded()
        let p = local ?? NSPoint(x: control.bounds.midX, y: control.bounds.midY)
        let result = try XCTUnwrap(root.hitTest(control.convert(p, to: root.superview)),
                                   "窗口根命中为空：\(control)", file: file, line: line)
        XCTAssertTrue(result === control || result.isDescendant(of: control),
                      "命中错误：\(control) -> \(result)", file: file, line: line)
        var ancestor = control.superview
        while let view = ancestor {
            let nested = view.hitTest(control.convert(p, to: view.superview))
            XCTAssertTrue(nested === control || nested?.isDescendant(of: control) == true,
                          "逐层命中错误：\(type(of: view))", file: file, line: line)
            if view === root { break }
            ancestor = view.superview
        }
        return result
    }

    /// 对命中后的真实 target/action 做连通检查；菜单选择不伪称系统菜单跟踪测试。
    private func dispatch(_ control: NSControl) throws {
        try hit(control)
        XCTAssertTrue(control.isEnabled)
        let action = try XCTUnwrap(control.action)
        XCTAssertTrue(control.sendAction(action, to: control.target))
    }

    private func mouseClick(_ control: NSControl, local: NSPoint? = nil) throws {
        let target = try hit(control, local: local)
        let window = try XCTUnwrap(control.window)
        let p = control.convert(local ?? NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [],
            timestamp: down.timestamp + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        // 将根命中的对象交回原生 mouseDown/跟踪循环，不直接调用按钮 action。
        target.mouseDown(with: down)
    }

    func testNativeMouseTrackingOfRealToolbarButtonsAndSegments() throws {
        for mode in 0..<3 {
            let (controller, window, glass, canvas) = try editor(zoom: false)
            defer { _ = controller.perform(NSSelectorFromString("closeWindow")) }
            glass.forceFallback = mode == 1
            glass.updateAccessibility(reduceTransparency: mode == 2)
            let segments = try XCTUnwrap(descendants(glass).compactMap { $0 as? NSSegmentedControl }.first)
            XCTAssertTrue(type(of: segments) == NSSegmentedControl.self)
            XCTAssertTrue(type(of: segments.cell!) == NSSegmentedCell.self)
            for (index, tool) in [AnnotationTool.pen, .eraser, .mosaic, .text].enumerated() {
                try mouseClick(segments, local: NSPoint(x: segments.bounds.width * (CGFloat(index) + 0.5) / 4, y: segments.bounds.midY))
                XCTAssertEqual(canvas.tool, tool)
            }
            let panel = try XCTUnwrap(window.childWindows?.first { $0.title == "标注参数" })
            let parameterGlass = try XCTUnwrap(panel.contentView as? GlassView)
            parameterGlass.forceFallback = mode == 1
            parameterGlass.updateAccessibility(reduceTransparency: mode == 2)
            let underline = try XCTUnwrap(descendants(parameterGlass).compactMap { $0 as? NSButton }.first { $0.title == "下划线" })
            try mouseClick(underline)
            XCTAssertTrue(canvas.textUnderline)
            let blue = try XCTUnwrap(descendants(parameterGlass).compactMap { $0 as? NSButton }.first {
                $0.action == NSSelectorFromString("colorSelected:") && $0.tag == 3
            })
            try mouseClick(blue)
            XCTAssertEqual(canvas.strokeColor, .systemBlue)
            var received: [String] = []
            controller.onCopy = { _ in received.append("复制") }
            controller.onSave = { _ in received.append("保存"); return false }
            controller.onPin = { _ in received.append("贴图") }
            controller.onClose = { received.append("关闭") }
            for title in ["清空", "复制", "保存", "贴图", "关闭"] {
                let button = try XCTUnwrap(descendants(glass).compactMap { $0 as? NSButton }.first { $0.toolTip == title })
                try mouseClick(button)
            }
            XCTAssertEqual(received, ["复制", "保存", "贴图", "关闭"])
        }
    }

    private func editor(zoom: Bool) throws -> (AnnotationEditorController, NSWindow, GlassView, AnnotationCanvasView) {
        _ = NSApplication.shared
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = AnnotationEditorController(image: NSImage(size: NSSize(width: 400, height: 300)), allowsZoom: zoom)
        controller.show()
        let window = try XCTUnwrap(NSApp.windows.first {
            !before.contains(ObjectIdentifier($0)) && $0.title == "截图编辑"
        })
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let glass = try XCTUnwrap(descendants(root).compactMap { $0 as? GlassView }.first)
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? AnnotationCanvasView }.first)
        return (controller, window, glass, canvas)
    }

    func testActualToolbarAllActionsParametersAndShadowAcrossBackends() throws {
        print("Toolbar runtime: \(ProcessInfo.processInfo.operatingSystemVersionString), AppKit \(NSAppKitVersion.current.rawValue)")
        for zoom in [false, true] {
            for mode in 0..<3 {
                let (controller, window, glass, canvas) = try editor(zoom: zoom)
                defer { _ = controller.perform(NSSelectorFromString("closeWindow")) }
                glass.forceFallback = mode == 1
                glass.updateAccessibility(reduceTransparency: mode == 2)
                let root = try XCTUnwrap(window.contentView)
                root.layoutSubtreeIfNeeded()
                print("Toolbar zoom=\(zoom) mode=\(mode) backend=\(glass.backend) frame=\(glass.frame) host=\(glass.controlsHost.frame)")
                XCTAssertFalse(window.hasShadow)
                XCTAssertFalse(root.layer?.masksToBounds ?? true)
                XCTAssertFalse(glass.layer?.masksToBounds ?? true)
                XCTAssertGreaterThanOrEqual(glass.frame.minY, GlassView.shadowPadding)
                XCTAssertGreaterThanOrEqual(glass.frame.minX, GlassView.shadowPadding)
                XCTAssertGreaterThanOrEqual(root.bounds.maxX - glass.frame.maxX, GlassView.shadowPadding)
                let halo = glass.frame.insetBy(dx: -26, dy: -26)
                XCTAssertTrue(root.bounds.contains(halo), "阴影过渡必须在窗口可见边界内")
                XCTAssertEqual(glass.effectView.layer?.shadowOpacity ?? 0, 0)
                XCTAssertEqual(glass.layer?.shadowOpacity ?? 0, glass.backend == .native ? 0 : 0.12, accuracy: 0.001)
                if glass.backend != .native {
                    XCTAssertNotNil(glass.layer?.shadowPath)
                    XCTAssertEqual(glass.layer?.shadowRadius, 8)
                }
                let controls = descendants(glass.controlsHost).compactMap { $0 as? NSControl }.filter { $0.action != nil }
                XCTAssertEqual(controls.count, 7) // segmented、形状和五个快捷按钮
                for control in controls { try hit(control) }
                let segments = try XCTUnwrap(controls.compactMap { $0 as? NSSegmentedControl }.first)
                let shapes = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first)
                for (index, tool) in [AnnotationTool.pen, .eraser, .mosaic, .text].enumerated() {
                    try hit(segments, local: NSPoint(x: segments.bounds.width * (CGFloat(index) + 0.5) / 4, y: segments.bounds.midY))
                    segments.selectedSegment = index
                    try dispatch(segments)
                    XCTAssertEqual(canvas.tool, tool)
                    if index == 0 || index == 3 {
                        try checkParameters(window: window, canvas: canvas, mode: mode, text: index == 3)
                    } else { XCTAssertTrue(window.childWindows?.isEmpty ?? true) }
                    try dispatch(segments)
                    XCTAssertEqual(canvas.tool, .none)
                }
                for (index, tool) in [AnnotationTool.rectangle, .oval, .line, .arrow].enumerated() {
                    shapes.selectItem(at: index)
                    try dispatch(shapes)
                    XCTAssertEqual(canvas.tool, tool)
                    XCTAssertEqual(segments.selectedSegment, -1)
                    XCTAssertEqual(shapes.layer?.borderWidth, 2)
                    try checkParameters(window: window, canvas: canvas, mode: mode, text: false)
                    try dispatch(shapes)
                    XCTAssertEqual(canvas.tool, .none)
                    XCTAssertEqual(shapes.layer?.borderWidth, 0)
                }
                var copied = 0, saved = 0, pinned = 0, closed = 0
                controller.onCopy = { _ in copied += 1 }
                controller.onSave = { _ in saved += 1; return false }
                controller.onPin = { _ in pinned += 1 }
                controller.onClose = { closed += 1 }
                for title in ["清空", "复制", "保存", "贴图", "关闭"] {
                    let button = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.toolTip == title })
                    try dispatch(button)
                }
                XCTAssertTrue(canvas.shapes.isEmpty)
                XCTAssertEqual(copied, 1); XCTAssertEqual(saved, 1)
                XCTAssertEqual(pinned, 1); XCTAssertEqual(closed, 1)
                XCTAssertFalse(window.isVisible)
            }
        }
    }

    private func checkParameters(window: NSWindow, canvas: AnnotationCanvasView, mode: Int, text: Bool) throws {
        let panel = try XCTUnwrap(window.childWindows?.first { $0.title == "标注参数" })
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        let glass = try XCTUnwrap(panel.contentView as? GlassView)
        glass.forceFallback = mode == 1
        glass.updateAccessibility(reduceTransparency: mode == 2)
        panel.contentView?.layoutSubtreeIfNeeded()
        let controls = descendants(glass.controlsHost).compactMap { $0 as? NSControl }
        for control in controls where control.action != nil { try hit(control) }
        // 参数文本目前均为只读标签，不冒充可编辑输入框。
        XCTAssertTrue(controls.compactMap { $0 as? NSTextField }.allSatisfy { !$0.isEditable })
        let slider = try XCTUnwrap(controls.compactMap { $0 as? NSSlider }.first)
        slider.doubleValue = text ? 32 : 9
        try dispatch(slider)
        XCTAssertEqual(text ? canvas.textPointSize : canvas.strokeWidth, text ? 32 : 9)
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white]
        for button in controls.compactMap({ $0 as? GlassButton }) where button.action == NSSelectorFromString("colorSelected:") {
            try dispatch(button)
            XCTAssertEqual(canvas.strokeColor, colors[button.tag])
            button.reduceMotionOverride = true
            button.reduceTransparencyOverride = mode == 2
            button.setHovered(true)
            XCTAssertFalse(button.hasFeedbackAnimation)
        }
        let palette = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.toolTip == "打开调色盘" })
        try dispatch(palette)
        XCTAssertTrue(NSColorPanel.shared.isVisible)
        NSColorPanel.shared.color = .purple
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("customColorChanged:"), to: palette.target, from: NSColorPanel.shared))
        XCTAssertEqual(canvas.strokeColor, .purple)
        if text {
            let popups = controls.compactMap { $0 as? NSPopUpButton }
            XCTAssertEqual(popups.count, 2)
            for popup in popups {
                for index in 0..<popup.numberOfItems {
                    popup.selectItem(at: index)
                    try dispatch(popup)
                    if popup.action == NSSelectorFromString("textFontChanged:") {
                        XCTAssertEqual(canvas.textFontName, popup.titleOfSelectedItem)
                    } else { XCTAssertEqual(canvas.textWeight.rawValue, index) }
                }
            }
            let underline = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "下划线" })
            underline.state = .on
            try dispatch(underline)
            XCTAssertTrue(canvas.textUnderline)
        }
    }

    func testOffsetBoundsPositionedInsertionAndEditableField() throws {
        _ = NSApplication.shared
        let panel = AnnotationEditorController.makeOptionsPanel(size: NSSize(width: 500, height: 280))
        defer { panel.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 280))
        panel.contentView = root
        let glass = GlassView(frame: NSRect(x: 73, y: 51, width: 320, height: 160))
        root.addSubview(glass)
        root.setBoundsOrigin(NSPoint(x: 9, y: 13))
        let field = NSTextField(frame: NSRect(x: 34, y: 42, width: 180, height: 24))
        glass.addSubview(field, positioned: .above, relativeTo: nil)
        for mode in 0..<3 {
            glass.forceFallback = mode == 1
            glass.updateAccessibility(reduceTransparency: mode == 2)
            root.layoutSubtreeIfNeeded()
            XCTAssertTrue(field.superview === glass.controlsHost)
            try hit(field)
            XCTAssertTrue(panel.makeFirstResponder(field))
            XCTAssertNotNil(field.currentEditor())
            panel.makeFirstResponder(nil)
            glass.isHidden = true
            XCTAssertNil(glass.hitTest(NSPoint(x: 120, y: 100)))
            glass.isHidden = false
            XCTAssertNil(glass.hitTest(NSPoint(x: 0, y: 0)))
        }
    }
}
