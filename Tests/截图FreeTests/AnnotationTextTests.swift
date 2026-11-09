import AppKit
import XCTest
@testable import 截图Free

@MainActor
final class AnnotationTextTests: XCTestCase {
    private func canvas() -> AnnotationCanvasView {
        _ = NSApplication.shared
        let view = AnnotationCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), image: NSImage(size: CGSize(width: 400, height: 300)))
        view.tool = .text
        return view
    }

    private func type(_ text: String, in canvas: AnnotationCanvasView) throws {
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    }

    func testActualTextKitFrameFitsShortLongMultilineAndShrinks() throws {
        let view = canvas()
        view.beginText(at: CGPoint(x: 30, y: 250))
        let editor = try XCTUnwrap(view.subviews.first as? NSTextView)
        XCTAssertLessThan(editor.frame.width, 25)
        for text in ["短文", String(repeating: "中文长文本 ABC ", count: 20), "第一行\n第二行\n", "a"] {
            try type(text, in: view)
            let container = try XCTUnwrap(editor.textContainer)
            let manager = try XCTUnwrap(editor.layoutManager)
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            XCTAssertEqual(editor.frame.width, min(container.containerSize.width, ceil(used.maxX) + 2), accuracy: 1)
            XCTAssertFalse(container.widthTracksTextView)
            XCTAssertFalse(container.heightTracksTextView)
            XCTAssertTrue(view.bounds.contains(editor.frame.insetBy(dx: -4, dy: -4)))
            if text == "短文" || text == "a" { XCTAssertLessThan(editor.frame.width, 80) }
            if text.contains("\n") { XCTAssertGreaterThan(editor.frame.height, 60) }
        }
    }

    func testMarkedTextSurvivesLayoutAndCommit() throws {
        let view = canvas()
        view.beginText(at: CGPoint(x: 30, y: 250))
        let editor = try XCTUnwrap(view.subviews.first as? NSTextView)
        editor.setMarkedText("中文输入", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        let selection = editor.selectedRange()
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertLessThan(editor.frame.width, 150)
        view.commitTextEditing()
        guard case let .text(text, _, _, _, _, _, _) = view.editableTexts[0] else { return XCTFail() }
        XCTAssertEqual(text, "中文输入")
    }

    func testTextFrameRemainsInsideCanvasAfterMoveAndZoom() throws {
        let view = canvas()
        view.beginText(at: CGPoint(x: 399, y: 1))
        try type("边界\n多行", in: view)
        for delta in [CGSize(width: -1000, height: -1000), CGSize(width: 1000, height: 1000)] {
            view.moveSelectedText(by: delta)
            let editor = try XCTUnwrap(view.subviews.first as? NSTextView)
            XCTAssertTrue(view.bounds.contains(editor.frame.insetBy(dx: -4, dy: -4)))
        }
        for size in [CGSize(width: 800, height: 600), CGSize(width: 200, height: 150)] {
            view.setCanvasDisplaySize(size)
            let editor = try XCTUnwrap(view.subviews.first as? NSTextView)
            XCTAssertTrue(view.bounds.contains(editor.frame.insetBy(dx: -4, dy: -4)))
            XCTAssertEqual(view.selectedTextIndex, 0)
        }
    }

    func testSwitchToolCommitsWithoutReopeningContentEditor() throws {
        let view = canvas()
        view.beginText(at: CGPoint(x: 30, y: 250))
        try type("文字", in: view)
        view.tool = .pen
        XCTAssertEqual(view.shapes.count, 1)
        XCTAssertTrue(view.editableTexts.isEmpty)
        XCTAssertTrue(view.subviews.isEmpty)
        view.tool = .text
        view.selectText(at: 0)
        view.textPointSize = 60
        XCTAssertNil(view.selectedTextIndex)
        guard case let .text(text, _, _, size, _, _, _) = view.shapes[0] else { return XCTFail() }
        XCTAssertEqual(text, "文字")
        XCTAssertEqual(size, 20)
    }

    func testMultipleTextsSelectionStyleAndMovement() throws {
        let view = canvas()
        view.beginText(at: CGPoint(x: 30, y: 250))
        try type("第一行\n第二行", in: view)
        view.beginText(at: CGPoint(x: 200, y: 200))
        try type("另一个", in: view)
        view.commitTextEditing()
        view.selectText(at: 0)
        view.textPointSize = 32
        view.textWeight = .bold
        view.textUnderline = true
        view.strokeColor = .blue
        view.moveSelectedText(by: CGSize(width: 10, height: -20))
        view.commitTextEditing()
        guard case let .text(text, origin, color, size, _, weight, underline) = view.editableTexts[0] else { return XCTFail() }
        XCTAssertEqual(text, "第一行\n第二行")
        XCTAssertEqual(origin, CGPoint(x: 40, y: 230))
        XCTAssertEqual(size, 32)
        XCTAssertEqual(weight, .bold)
        XCTAssertTrue(underline)
        XCTAssertEqual(color, .blue)
        XCTAssertEqual(view.editableTexts.count, 2)
    }

    func testZoomPreservesSelectionAndScalesText() throws {
        let view = canvas()
        view.beginText(at: CGPoint(x: 30, y: 250))
        try type("缩放", in: view)
        view.setCanvasDisplaySize(CGSize(width: 800, height: 600))
        XCTAssertEqual(view.selectedTextIndex, 0)
        guard case let .text(_, origin, _, size, _, _, _) = view.editableTexts[0] else { return XCTFail() }
        XCTAssertEqual(origin, CGPoint(x: 60, y: 500))
        XCTAssertEqual(size, 40)
        view.setCanvasDisplaySize(CGSize(width: 400, height: 300))
        XCTAssertEqual(view.textPointSize, 20)
    }

    func testEscapeCommitsAndEmptyTextIsDiscarded() throws {
        let view = canvas()
        view.beginText(at: CGPoint(x: 30, y: 250))
        try type("保留", in: view)
        let editor = try XCTUnwrap(view.subviews.first as? NSTextView)
        editor.cancelOperation(nil)
        XCTAssertNil(view.selectedTextIndex)
        XCTAssertEqual(view.editableTexts.count, 1)
        view.beginText(at: CGPoint(x: 100, y: 200))
        view.commitTextEditing()
        XCTAssertEqual(view.editableTexts.count, 1)
        view.clear()
        XCTAssertTrue(view.editableTexts.isEmpty)
    }

    func testExportCommitsWithoutDuplicateOrEditor() throws {
        let view = canvas()
        view.beginText(at: CGPoint(x: 30, y: 250))
        try type("导出", in: view)
        XCTAssertEqual(view.renderedImage(scale: 2).size, CGSize(width: 800, height: 600))
        XCTAssertNil(view.selectedTextIndex)
        XCTAssertTrue(view.subviews.isEmpty)
        _ = view.renderedImage()
        XCTAssertEqual(view.editableTexts.count, 1)
        view.tool = .none
        XCTAssertEqual(view.shapes.count, 1)
    }

    func testCanvasLongPressMovesSessionAndFixedText() throws {
        let view = canvas()
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 30, y: 250)))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 30, y: 250)))
        try type("拖动", in: view)
        view.commitTextEditing()
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 32, y: 245)))
        let pressed = expectation(description: "真实长按计时器触发")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pressed.fulfill() }
        wait(for: [pressed], timeout: 2)
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 52, y: 225)))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 52, y: 225)))
        guard case let .text(_, origin, _, _, _, _, _) = view.editableTexts[0] else { return XCTFail() }
        XCTAssertEqual(origin, CGPoint(x: 50, y: 230))
        view.tool = .rectangle
        view.tool = .none
        let fixed = view.shapes
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 52, y: 225)))
        let held = expectation(description: "固定文字也可长按")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { held.fulfill() }
        wait(for: [held], timeout: 2)
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 72, y: 205)))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 72, y: 205)))
        XCTAssertNil(view.subviews.first as? NSTextView)
        XCTAssertEqual(view.shapes.count, 1)
        XCTAssertNotEqual(view.shapes, fixed)
        let moved = view.shapes
        view.undoAnnotation()
        XCTAssertEqual(view.shapes, fixed)
        view.redoAnnotation()
        XCTAssertEqual(view.shapes, moved)
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 72, y: 205)))
        let resize = expectation(description: "固定文字长按后保留字号手柄")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { resize.fulfill() }
        wait(for: [resize], timeout: 2)
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 72, y: 205)))
        let handle = try XCTUnwrap(view.subviews.first)
        handle.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        handle.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 140, y: 100)))
        handle.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 140, y: 100)))
        guard case let .text(_, _, _, resizedSize, _, _, _) = view.shapes[0] else { return XCTFail() }
        XCTAssertEqual(resizedSize, 34)
        view.undoAnnotation()
        XCTAssertEqual(view.shapes, moved)
        view.dispose()
        window.contentView = nil
    }

    func testRealInputMarkedNewlineDeleteUndoFrameAndParameters() throws {
        let view = canvas()
        view.beginText(at: CGPoint(x: 30, y: 250))
        let editor = try XCTUnwrap(view.subviews.first as? NSTextView)
        let manager = try XCTUnwrap(editor.undoManager)
        manager.groupsByEvent = false
        let empty = editor.frame
        manager.beginUndoGrouping()
        editor.insertText("第一行较长文字\n第二行\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        manager.endUndoGrouping()
        let grown = editor.frame
        XCTAssertGreaterThan(grown.width, empty.width)
        XCTAssertGreaterThan(grown.height, empty.height * 2)
        manager.undo()
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(editor.frame.size, empty.size)
        manager.redo()
        XCTAssertEqual(editor.frame.size, grown.size)
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        manager.beginUndoGrouping()
        editor.deleteBackward(nil)
        manager.endUndoGrouping()
        XCTAssertEqual(editor.frame.size, empty.size)
        editor.setMarkedText("中文组合输入很长", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let long = editor.frame.width
        editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertLessThan(editor.frame.width, long)
        view.textPointSize = 32
        view.strokeColor = .blue
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(view.subviews.contains { $0 === editor })
        editor.unmarkText()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(view.selectedTextIndex, 0)
        XCTAssertGreaterThan(editor.frame.height, empty.height)
    }

    func testOneShotOutsideClickShortPressAndTimerCancellation() throws {
        let view = canvas()
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { view.dispose(); window.contentView = nil }
        func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        let origin = CGPoint(x: 30, y: 250)
        let outside = CGPoint(x: 260, y: 60)
        try send(.leftMouseDown, origin)
        try send(.leftMouseUp, origin)
        try type("保留文字", in: view)
        view.textPointSize = 24
        view.strokeColor = .green
        XCTAssertEqual(view.selectedTextIndex, 0)
        try send(.leftMouseDown, outside)
        try send(.leftMouseUp, outside)
        XCTAssertNil(view.selectedTextIndex)
        XCTAssertFalse(view.textCreationArmed)
        try send(.leftMouseDown, outside)
        try send(.leftMouseUp, outside)
        XCTAssertEqual(view.shapes.count, 1)
        XCTAssertEqual(view.tool, .none)
        XCTAssertTrue(view.subviews.isEmpty)
        let before = view.shapes
        let hit = CGPoint(x: 32, y: 240)
        try send(.leftMouseDown, hit)
        try send(.leftMouseDragged, CGPoint(x: 60, y: 220))
        try send(.leftMouseUp, hit)
        XCTAssertEqual(view.shapes, before)
        try send(.leftMouseDown, hit)
        view.tool = .rectangle
        let fixed = view.shapes
        let cancelled = expectation(description: "松手和切工具后的延迟回调已取消")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { cancelled.fulfill() }
        wait(for: [cancelled], timeout: 2)
        XCTAssertTrue(view.subviews.isEmpty)
        XCTAssertEqual(view.shapes, fixed)
        view.tool = .text
        try send(.leftMouseDown, outside)
        try send(.leftMouseUp, outside)
        XCTAssertNotNil(view.selectedTextIndex)
        view.commitTextEditing()
        try send(.leftMouseDown, hit)
        view.dispose()
        let disposed = expectation(description: "销毁后计时器不得新建控件")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { disposed.fulfill() }
        wait(for: [disposed], timeout: 2)
        XCTAssertTrue(view.subviews.isEmpty)
    }
}
