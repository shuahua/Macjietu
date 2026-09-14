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
        editor.string = text
        canvas.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
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
        view.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
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

    func testSwitchToolPermanentlyFreezesText() throws {
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

    func testCanvasMouseCreatesSelectsAndDragsOnlySessionText() throws {
        let view = canvas()
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 30, y: 250)))
        try type("拖动", in: view)
        view.commitTextEditing()
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 32, y: 245)))
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 52, y: 225)))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 52, y: 225)))
        guard case let .text(_, origin, _, _, _, _, _) = view.editableTexts[0] else { return XCTFail() }
        XCTAssertEqual(origin, CGPoint(x: 50, y: 230))
        view.tool = .rectangle
        view.tool = .text
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 52, y: 225)))
        let editor = try XCTUnwrap(view.subviews.first as? NSTextView)
        XCTAssertTrue(editor.string.isEmpty)
        XCTAssertEqual(view.shapes.count, 1)
        view.dispose()
        window.contentView = nil
    }
}
