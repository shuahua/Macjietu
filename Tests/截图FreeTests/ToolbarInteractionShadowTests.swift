import AppKit
import XCTest
@testable import 截图Free

@MainActor
final class ToolbarInteractionShadowTests: XCTestCase {
    @MainActor private final class ActionProbe: NSObject {
        var count = 0
        @objc func invoke(_ sender: NSSegmentedControl) {
            count += 1
        }
    }

    func testFiveMomentaryActionsReleaseCancelRepeatAndKeyboard() throws {
        for mode in 0..<3 {
            let (controller, window, glass, canvas) = try editor(zoom: false)
            defer { _ = controller.perform(NSSelectorFromString("closeWindow")) }
            glass.forceFallback = mode == 1
            glass.updateAccessibility(reduceTransparency: mode == 2)
            let controls = descendants(glass)
            let textButton = try XCTUnwrap(controls.compactMap { $0 as? NSSegmentedControl }.first)
            textButton.selectedSegment = 3
            try dispatch(textButton)
            let buttons = controls.compactMap { $0 as? NSSegmentedControl }.filter { $0.trackingMode == .momentary }
            XCTAssertEqual(buttons.count, 5)
            for title in ["清空", "复制", "保存", "贴图", "关闭"] {
                let button = try XCTUnwrap(buttons.first { $0.toolTip == title })
                let cell = try XCTUnwrap(button.cell as? NSSegmentedCell)
                XCTAssertEqual(button.segmentStyle, textButton.segmentStyle)
                let probe = ActionProbe()
                button.target = probe
                button.action = #selector(ActionProbe.invoke(_:))
                _ = window.makeFirstResponder(button)
                func assertIdle() {
                    XCTAssertEqual(button.selectedSegment, -1)
                    XCTAssertFalse(button.isSelected(forSegment: 0))
                    XCTAssertFalse(cell.isHighlighted)
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
                    NSApp.postEvent(up, atStart: true)
                    if cancel { NSApp.postEvent(drag, atStart: true) }
                    target.mouseDown(with: down)
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
                XCTAssertEqual(textButton.selectedSegment, 3)
                XCTAssertEqual(canvas.tool, .text)
            }
            let shapes = try XCTUnwrap(controls.compactMap { $0 as? NSSegmentedControl }.first { $0.toolTip == "直线" })
            try dispatch(shapes)
            for button in buttons { button.performClick(nil) }
            XCTAssertEqual(canvas.tool, .line)
            XCTAssertEqual(shapes.selectedSegment, 0)
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
            for (index, tool) in [AnnotationTool.pen, .eraser, .mosaic, .text].enumerated() {
                let button = try XCTUnwrap(descendants(glass).compactMap { $0 as? NSSegmentedControl }.first)
                try mouseClick(button, local: NSPoint(x: button.bounds.width * (CGFloat(index) + 0.5) / 4, y: button.bounds.midY))
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
                let button = try XCTUnwrap(descendants(glass).compactMap { $0 as? NSSegmentedControl }.first { $0.toolTip == title })
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

    func testRealEditorOutsideTextClickExitsNativeSelectionAndRequiresRearm() throws {
        for zoom in [false, true] {
            for mode in 0..<3 {
                let (controller, window, glass, canvas) = try editor(zoom: zoom)
                defer { _ = controller.perform(NSSelectorFromString("closeWindow")) }
                glass.forceFallback = mode == 1
                glass.updateAccessibility(reduceTransparency: mode == 2)
                let segments = descendants(glass).compactMap { $0 as? NSSegmentedControl }
                XCTAssertEqual(segments.count, 10, "左侧四段、四个形状和五个操作全部使用原生分段")
                let tools = try XCTUnwrap(segments.first)
                XCTAssertEqual(tools.segmentStyle, .separated)
                XCTAssertEqual(tools.trackingMode, .selectOne)
                XCTAssertEqual(tools.selectedSegment, -1)
                for index in 0..<4 {
                    XCTAssertEqual(tools.label(forSegment: index), "")
                    XCTAssertNotNil(tools.image(forSegment: index))
                }
                XCTAssertEqual(tools.toolTip(forSegment: 3), "文字")
                XCTAssertFalse(descendants(glass).compactMap { $0 as? NSButton }.contains {
                    ["画笔", "橡皮", "马赛克", "文字", "格式"].contains($0.toolTip ?? "") || $0.title == "格式"
                })
                var revisions: [UInt64] = []
                controller.onContentChange = { revisions.append($0) }
                func select(_ index: Int) throws {
                    try mouseClick(tools, local: NSPoint(x: tools.bounds.width * (CGFloat(index) + 0.5) / 4, y: tools.bounds.midY))
                }
                func canvasClick(_ point: CGPoint) throws {
                    let target = try hit(canvas, local: point)
                    let p = canvas.convert(point, to: nil)
                    func event(_ type: NSEvent.EventType) -> NSEvent {
                        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                    }
                    let up = event(.leftMouseUp)
                    // 无工具时 AppKit 的窗口拖动可能消费 mouseUp；供原生循环读取。
                    if canvas.tool == .none { NSApp.postEvent(up, atStart: true) }
                    target.mouseDown(with: event(.leftMouseDown))
                    target.mouseUp(with: up)
                }
                try select(0)
                XCTAssertEqual(tools.selectedSegment, 0)
                // 未选择文字前，画笔也必须接通自动复制通知。
                let p = canvas.convert(CGPoint(x: 20, y: 20), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x + (type == .leftMouseDown ? 0 : 30), y: p.y), modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                    switch type {
                    case .leftMouseDown: canvas.mouseDown(with: event)
                    case .leftMouseDragged: canvas.mouseDragged(with: event)
                    default: canvas.mouseUp(with: event)
                    }
                }
                XCTAssertFalse(revisions.isEmpty)
                canvas.clear()
                try select(3)
                XCTAssertEqual(canvas.tool, .text)
                try canvasClick(CGPoint(x: 30, y: 250))
                let input = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
                XCTAssertTrue(window.firstResponder === input)
                input.insertText("真实编辑器输入", replacementRange: NSRange(location: NSNotFound, length: 0))
                let typedRevision = canvas.contentRevision
                try canvasClick(CGPoint(x: 300, y: 50))
                XCTAssertEqual(canvas.tool, .none)
                XCTAssertEqual(tools.selectedSegment, -1)
                XCTAssertFalse(canvas.textCreationArmed)
                XCTAssertNil(canvas.selectedTextIndex)
                XCTAssertTrue(canvas.subviews.isEmpty)
                XCTAssertTrue(window.firstResponder === canvas)
                XCTAssertTrue(window.childWindows?.isEmpty ?? true)
                XCTAssertEqual(canvas.contentRevision, typedRevision, "状态退出不得重复自动复制")
                XCTAssertEqual(canvas.shapes.count, 1)
                try canvasClick(CGPoint(x: 300, y: 50))
                XCTAssertTrue(canvas.subviews.isEmpty)
                XCTAssertEqual(canvas.shapes.count, 1)
                canvas.undoAnnotation()
                XCTAssertTrue(canvas.shapes.isEmpty)
                canvas.redoAnnotation()
                XCTAssertEqual(canvas.shapes.count, 1)
                XCTAssertEqual(tools.selectedSegment, -1)
                try select(3)
                try canvasClick(CGPoint(x: 200, y: 150))
                XCTAssertNotNil(canvas.selectedTextIndex)
                // 空输入外点也退出；已有文字不被删除。
                try canvasClick(CGPoint(x: 300, y: 50))
                XCTAssertEqual(tools.selectedSegment, -1)
                XCTAssertEqual(canvas.shapes.count, 1)
                let shape = try XCTUnwrap(descendants(glass).compactMap { $0 as? NSSegmentedControl }.first { $0.toolTip == "矩形" })
                try mouseClick(shape)
                XCTAssertEqual(shape.selectedSegment, 0)
                XCTAssertEqual(tools.selectedSegment, -1)
                try select(0)
                XCTAssertEqual(tools.selectedSegment, 0)
                XCTAssertEqual(shape.selectedSegment, -1)
            }
        }
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
                XCTAssertEqual(controls.count, 10) // 全部为原生分段控件
                XCTAssertEqual(controls.compactMap { $0 as? NSSegmentedControl }.count, 10)
                for case let control as NSSegmentedControl in controls {
                    XCTAssertEqual(control.segmentStyle, .separated)
                    XCTAssertEqual(control.controlSize, .regular)
                    for index in 0..<control.segmentCount {
                        XCTAssertEqual(control.label(forSegment: index), "")
                        XCTAssertNotNil(control.image(forSegment: index))
                    }
                }
                let textIcon = try XCTUnwrap((controls.first as? NSSegmentedControl)?.image(forSegment: 3))
                XCTAssertTrue(textIcon.isTemplate)
                XCTAssertEqual(textIcon.accessibilityDescription, "文字 Aa")
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(textIcon.tiffRepresentation)))
                XCTAssertTrue((0..<bitmap.pixelsHigh).contains { y in
                    (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
                }, "Aa 必须有真实非透明像素")
                let group = controls.reduce(CGRect.null) { $0.union($1.convert($1.bounds, to: glass)) }
                XCTAssertEqual(group.midX, glass.bounds.midX, accuracy: 0.5)
                XCTAssertTrue(glass.bounds.contains(group))
                XCTAssertEqual(glass.bounds.width, 600)
                XCTAssertGreaterThanOrEqual(group.minX, 27)
                XCTAssertGreaterThanOrEqual(glass.bounds.maxX - group.maxX, 27)
                if let screen = window.screen { XCTAssertTrue(screen.visibleFrame.contains(window.frame)) }
                for control in controls { try hit(control) }
                for (index, tool) in [AnnotationTool.pen, .eraser, .mosaic, .text].enumerated() {
                    let button = try XCTUnwrap(controls.compactMap { $0 as? NSSegmentedControl }.first)
                    button.selectedSegment = index
                    try dispatch(button)
                    XCTAssertEqual(canvas.tool, tool)
                    if index == 0 || index == 3 {
                        try checkParameters(window: window, canvas: canvas, mode: mode, text: index == 3)
                    } else { XCTAssertTrue(window.childWindows?.isEmpty ?? true) }
                    try dispatch(button)
                    XCTAssertEqual(canvas.tool, tool == .text ? .text : .none)
                }
                for tool in [AnnotationTool.rectangle, .oval, .line, .arrow] {
                    let shapes = try XCTUnwrap(controls.compactMap { $0 as? NSSegmentedControl }.first { $0.toolTip == tool.rawValue })
                    try mouseClick(shapes)
                    XCTAssertEqual(canvas.tool, tool)
                    XCTAssertEqual(controls.compactMap { $0 as? NSSegmentedControl }.filter { $0.selectedSegment >= 0 }.count, 1)
                    XCTAssertEqual(shapes.selectedSegment, 0)
                    try checkParameters(window: window, canvas: canvas, mode: mode, text: false)
                    try mouseClick(shapes)
                    XCTAssertEqual(canvas.tool, .none)
                    XCTAssertEqual(shapes.selectedSegment, -1)
                }
                var copied = 0, saved = 0, pinned = 0, closed = 0
                controller.onCopy = { _ in copied += 1 }
                controller.onSave = { _ in saved += 1; return false }
                controller.onPin = { _ in pinned += 1 }
                controller.onClose = { closed += 1 }
                for title in ["清空", "复制", "保存", "贴图", "关闭"] {
                    let button = try XCTUnwrap(controls.compactMap { $0 as? NSSegmentedControl }.first { $0.toolTip == title })
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
