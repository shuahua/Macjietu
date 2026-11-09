import AppKit
import XCTest
@testable import 截图Free

@MainActor
final class AnnotationUndoTests: XCTestCase {
    private func fixture() -> (AnnotationEditorWindow, AnnotationCanvasView) {
        _ = NSApplication.shared
        let size = CGSize(width: 400, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        NSColor.black.setFill()
        CGRect(x: 20, y: 20, width: 37, height: 41).fill()
        image.unlockFocus()
        let canvas = AnnotationCanvasView(frame: CGRect(origin: .zero, size: size), image: image)
        let window = AnnotationEditorWindow(contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.annotationCanvas = canvas
        window.makeFirstResponder(canvas)
        return (window, canvas)
    }

    private func event(_ type: NSEvent.EventType, _ point: CGPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    private func drag(_ canvas: AnnotationCanvasView, window: NSWindow, from: CGPoint = CGPoint(x: 30, y: 30), to: CGPoint = CGPoint(x: 130, y: 130)) throws {
        canvas.mouseDown(with: try event(.leftMouseDown, from, window: window))
        if canvas.tool == .text {
            let held = expectation(description: "长按文字")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { held.fulfill() }
            wait(for: [held], timeout: 2)
        }
        for fraction in [0.2, 0.5, 0.8] {
            canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction), window: window))
        }
        canvas.mouseUp(with: try event(.leftMouseUp, to, window: window))
    }

    private func key(_ window: NSWindow, redo: Bool = false) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: redo ? [.command, .shift] : [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: redo ? "Z" : "z",
            charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
    }

    private func pixels(_ canvas: AnnotationCanvasView) throws -> Data {
        let cg = try XCTUnwrap(ImageEncoding.sourceCGImage(from: canvas.renderedImage()))
        let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Data(bytes: try XCTUnwrap(context.data), count: cg.width * cg.height * 4)
    }

    func testEveryDrawingDragIsOneTransactionAndExportRestoresExactly() throws {
        for tool in [AnnotationTool.pen, .rectangle, .oval, .line, .arrow, .mosaic] {
            let (window, canvas) = fixture()
            let original = try pixels(canvas)
            canvas.tool = tool
            try drag(canvas, window: window)
            let annotated = try pixels(canvas)
            let automaticPNG = try XCTUnwrap(canvas.automaticCopySnapshot())()
            XCTAssertEqual(automaticPNG, try ImageEncoding.pngData(from: canvas.renderedImage()), "自动与现有导出必须一致：\(tool)")
            XCTAssertEqual(canvas.shapes.count, 1)
            XCTAssertNotEqual(original, annotated)
            try key(window)
            XCTAssertTrue(canvas.shapes.isEmpty)
            XCTAssertFalse(canvas.canUndoAnnotation)
            XCTAssertEqual(try pixels(canvas), original)
            try key(window, redo: true)
            XCTAssertEqual(try pixels(canvas), annotated)
        }
    }

    func testEraseClearBranchAndEditorIsolation() throws {
        let (window, canvas) = fixture()
        let (_, other) = fixture()
        canvas.tool = .rectangle
        try drag(canvas, window: window)
        canvas.tool = .arrow
        try drag(canvas, window: window, from: CGPoint(x: 240, y: 180), to: CGPoint(x: 340, y: 250))
        let both = canvas.shapes
        canvas.tool = .eraser
        try drag(canvas, window: window, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 300, y: 220))
        XCTAssertTrue(canvas.shapes.isEmpty)
        try key(window)
        XCTAssertEqual(canvas.shapes, both)
        canvas.clear()
        try key(window)
        XCTAssertEqual(canvas.shapes, both)
        try key(window)
        XCTAssertEqual(canvas.shapes.count, 1)
        canvas.tool = .oval
        try drag(canvas, window: window)
        XCTAssertFalse(canvas.canRedoAnnotation)
        XCTAssertFalse(other.canUndoAnnotation)
    }

    func testTextCreationStyleMoveResizeClearAndFrozenSession() throws {
        let (window, canvas) = fixture()
        canvas.tool = .text
        canvas.beginText(at: CGPoint(x: 60, y: 240))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.string = "撤销文字"
        canvas.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        canvas.commitTextEditing()
        let created = canvas.editableTexts
        canvas.selectText(at: 0)
        canvas.textUnderline = true
        canvas.commitTextEditing()
        canvas.undoAnnotation()
        XCTAssertEqual(canvas.editableTexts, created)
        canvas.selectText(at: 0)
        let handle = try XCTUnwrap(canvas.subviews.first { !($0 is NSTextView) })
        handle.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100), window: window))
        for x in [120, 140, 160] { handle.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: x, y: 100), window: window)) }
        handle.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 160, y: 100), window: window))
        canvas.commitTextEditing()
        XCTAssertNotEqual(canvas.editableTexts, created)
        canvas.undoAnnotation()
        XCTAssertEqual(canvas.editableTexts, created)
        try drag(canvas, window: window, from: CGPoint(x: 62, y: 230), to: CGPoint(x: 130, y: 200))
        canvas.commitTextEditing()
        XCTAssertNotEqual(canvas.editableTexts, created)
        canvas.undoAnnotation()
        XCTAssertEqual(canvas.editableTexts, created)
        canvas.tool = .pen
        let fixed = try pixels(canvas)
        canvas.clear()
        canvas.tool = .text
        try key(window)
        XCTAssertEqual(canvas.shapes, created)
        XCTAssertTrue(canvas.editableTexts.isEmpty)
        XCTAssertEqual(try pixels(canvas), fixed)
        try key(window)
        XCTAssertTrue(canvas.shapes.isEmpty)
        XCTAssertFalse(canvas.canUndoAnnotation)
    }

    func testNativeTextUndoAndMarkedTextTakePriorityOverCanvas() throws {
        let (window, canvas) = fixture()
        canvas.tool = .rectangle
        try drag(canvas, window: window)
        canvas.tool = .text
        canvas.beginText(at: CGPoint(x: 60, y: 240))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        window.makeFirstResponder(editor)
        let manager = try XCTUnwrap(editor.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        editor.insertText("输入", replacementRange: NSRange(location: NSNotFound, length: 0))
        manager.endUndoGrouping()
        XCTAssertTrue(manager.canUndo)
        try key(window)
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(canvas.shapes.count, 1)
        try key(window, redo: true)
        XCTAssertEqual(editor.string, "输入")
        manager.groupsByEvent = true
        editor.setMarkedText("组合", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        let value = editor.string
        try key(window)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.string, value)
        XCTAssertEqual(canvas.shapes.count, 1)
    }

    func testZoomTransformsHistoryAndNoOpToolsDoNotCreateHistory() throws {
        let (window, canvas) = fixture()
        canvas.tool = .pen
        canvas.tool = .text
        canvas.beginText(at: CGPoint(x: 50, y: 200))
        canvas.tool = .rectangle
        XCTAssertFalse(canvas.canUndoAnnotation)
        try drag(canvas, window: window)
        canvas.setCanvasDisplaySize(CGSize(width: 800, height: 600))
        let scaled = canvas.shapes
        try key(window)
        XCTAssertTrue(canvas.shapes.isEmpty)
        try key(window, redo: true)
        XCTAssertEqual(canvas.shapes, scaled)
    }
}
