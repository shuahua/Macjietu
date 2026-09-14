import AppKit
import XCTest
@testable import 截图Free

@MainActor
final class PinWindowControllerTests: XCTestCase {
    private func pin() -> PinWindowController {
        _ = NSApplication.shared
        let controller = PinWindowController(image: NSImage(size: CGSize(width: 300, height: 200)))
        controller.show()
        return controller
    }

    func testEscapeClosesOnlyItsPinAndClearsRetainedView() throws {
        let first = pin()
        let second = pin()
        defer { first.close(); second.close() }
        let window = try XCTUnwrap(first.window)
        let view = try XCTUnwrap(window.contentView as? PinnedImageView)
        XCTAssertTrue(view.subviews.isEmpty)
        XCTAssertEqual(view.bounds, view.imageRect)
        XCTAssertEqual(window.frame.size, CGSize(width: 300, height: 200))
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertTrue(view.mouseDownCanMoveWindow)
        XCTAssertTrue(window.canBecomeKey)
        let image = WeakBox(first.image)
        var calls = 0
        first.onClose = {
            calls += 1
            XCTAssertNil(first.image)
            XCTAssertNil(first.window)
            XCTAssertNil(first.onClose)
            first.close()
        }
        view.cancelOperation(nil)
        first.close()
        window.close()
        view.cancelOperation(nil)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(image.value)
        XCTAssertNil(view.image)
        XCTAssertNil(window.contentView)
        XCTAssertNil(window.delegate)
        XCTAssertNotNil(second.image)
        XCTAssertTrue(second.window?.isVisible == true)
        first.show()
        XCTAssertNil(first.window)
    }

    func testContextMenuAndEscapeAndNativeClose() throws {
        for entry in 0..<4 {
            let controller = pin()
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            let view = try XCTUnwrap(window.contentView as? PinnedImageView)
            var calls = 0
            controller.onClose = { calls += 1 }
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53))
            switch entry {
            case 0:
                let rightClick = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
                    location: CGPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                let menu = try XCTUnwrap(view.menu(for: rightClick))
                XCTAssertEqual(menu.items.map(\.title), ["关闭贴图"])
                menu.performActionForItem(at: 0)
            case 1: window.sendEvent(event)
            case 2: window.performClose(nil)
            default: window.close()
            }
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
            controller.close()
            XCTAssertEqual(calls, 1, "入口 \(entry)")
            XCTAssertNil(controller.window)
            XCTAssertNil(controller.image)
            XCTAssertNil(view.image)
        }
    }

    func testCoordinatorReleasesOnlyClosedControllerAndStopClosesRemainder() throws {
        _ = NSApplication.shared
        let coordinator = AppCoordinator()
        defer { coordinator.stop() }
        let first = WeakBox<PinWindowController>(nil)
        let second = WeakBox<PinWindowController>(nil)
        let image = WeakBox<NSImage>(nil)
        let window = WeakBox<NSWindow>(nil)
        autoreleasepool {
            coordinator.pin(image: NSImage(size: CGSize(width: 200, height: 100)))
            coordinator.pin(image: NSImage(size: CGSize(width: 100, height: 200)))
            first.value = coordinator.pinnedWindows.first
            second.value = coordinator.pinnedWindows.last
            image.value = first.value?.image
            window.value = first.value?.window
            first.value?.close()
        }
        XCTAssertNil(first.value)
        XCTAssertNil(image.value)
        XCTAssertNil(window.value)
        XCTAssertEqual(coordinator.pinnedWindows.count, 1)
        XCTAssertTrue(coordinator.pinnedWindows.first === second.value)
        XCTAssertTrue(second.value?.window?.isVisible == true)
        autoreleasepool { coordinator.stop() }
        XCTAssertTrue(coordinator.pinnedWindows.isEmpty)
        XCTAssertNil(second.value)
    }

    func testCloseBeforeShowAndDuplicateShowAreIdempotent() {
        _ = NSApplication.shared
        let controller = PinWindowController(image: NSImage(size: CGSize(width: 100, height: 100)))
        var calls = 0
        controller.onClose = { calls += 1 }
        controller.close()
        controller.close()
        controller.show()
        XCTAssertEqual(calls, 1)
        XCTAssertNil(controller.image)
        XCTAssertNil(controller.window)
        let shown = pin()
        let window = shown.window
        shown.show()
        XCTAssertTrue(window === shown.window)
        shown.close()
    }

    func testScreenBoundsAndResizeHaveNoButtonOrReservedSpace() throws {
        let screen = CGRect(x: -900, y: -200, width: 600, height: 400)
        for size in [CGSize(width: 5000, height: 10000), CGSize(width: 10000, height: 10), .zero] {
            let frame = PinWindowController.initialFrame(imageSize: size, visibleFrame: screen)
            XCTAssertTrue(screen.contains(frame))
            if size.width > 0, size.height > 0 {
                XCTAssertEqual(frame.width / frame.height, size.width / size.height, accuracy: 0.001)
            }
        }
        let controller = pin()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let view = try XCTUnwrap(window.contentView as? PinnedImageView)
        for size in [CGSize(width: 40, height: 48), CGSize(width: 800, height: 600)] {
            window.setContentSize(size)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(view.subviews.isEmpty)
            XCTAssertEqual(view.bounds, view.imageRect)
        }
    }
}
