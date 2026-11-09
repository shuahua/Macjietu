import AppKit
import XCTest
@testable import 截图Free

private extension NSWindow {
    var shelfTestContent: NSView? { (contentView as? ShelfViewport)?.content ?? contentView }
}

@MainActor final class ScreenshotShelfTests: XCTestCase {
    func testRenderedRopeHasVisiblyTaperedSilhouette() throws {
        _ = NSApplication.shared
        let rope = ShelfRope(frame: CGRect(x: 0, y: 0, width: 600, height: 46))
        let bitmap = try XCTUnwrap(rope.bitmapImageRepForCachingDisplay(in: rope.bounds))
        rope.cacheDisplay(in: rope.bounds, to: bitmap)
        func coverage(_ fraction: CGFloat) -> CGFloat {
            let x = Int(CGFloat(bitmap.pixelsWide - 1) * fraction)
            return (0..<bitmap.pixelsHigh).reduce(CGFloat(0)) { $0 + (bitmap.colorAt(x: x, y: $1)?.alphaComponent ?? 0) }
        }
        XCTAssertGreaterThan(coverage(0.5), coverage(0.02) * 1.8)
        XCTAssertGreaterThan(coverage(0.5), coverage(0.98) * 1.8)
    }

    func testIntermediatePivotGeometryAtNonzeroWindowOrigins() throws {
        _ = NSApplication.shared
        let model = ScreenshotShelfModel(), id = UUID()
        XCTAssertTrue(model.put(id: id, png: try ImageEncoding.pngData(from: image()), insert: true))
        for origin in [CGPoint(x: -1200, y: 900), CGPoint(x: 220, y: -800), CGPoint(x: 1400, y: 120)] {
            let window = NSWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 220, height: 180)), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "支点几何-\(id)"
            defer { window.orderOut(nil) }
            let card = ShelfCard(item: model.items[0], frame: CGRect(x: 17, y: 23, width: 154, height: 132))
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 180)); root.wantsLayer = true
            window.contentView = root; root.addSubview(card); card.layoutSubtreeIfNeeded()
            let layer = try XCTUnwrap(card.layer), parent = try XCTUnwrap(root.layer)
            let pivot = ShelfGeometry.pivot(card.decorationBounds)
            let expected = window.convertPoint(toScreen: CGPoint(x: card.frame.minX + pivot.x, y: card.frame.minY + pivot.y))
            let lower = CGPoint(x: card.photoRect.minX, y: card.photoRect.minY)
            let baseline = layer.convert(lower, to: parent)
            for fraction in [CGFloat(0.15), 0.35, 0.6, 0.85] {
                // 完整矩阵插值对应 hover 动画中途，不只检查终态配置。
                let end = card.pivotTransform(angle: 0.018, scale: 1.03)
                var t = CATransform3DIdentity
                t.m11 += (end.m11 - 1) * fraction; t.m12 = end.m12 * fraction
                t.m21 = end.m21 * fraction; t.m22 += (end.m22 - 1) * fraction
                t.m41 = end.m41 * fraction; t.m42 = end.m42 * fraction
                CATransaction.begin(); CATransaction.setDisableActions(true); layer.transform = t; CATransaction.commit()
                card.configurePivot()
                let actual = window.convertPoint(toScreen: layer.convert(pivot, to: parent))
                XCTAssertEqual(actual.x, expected.x, accuracy: 0.001); XCTAssertEqual(actual.y, expected.y, accuracy: 0.001)
                let moved = layer.convert(lower, to: parent)
                XCTAssertGreaterThan(hypot(moved.x - baseline.x, moved.y - baseline.y), 0.1)
            }
        }
    }
    func testViewportAcrossScreenArrangementsAndBackingScales() {
        for origin in [CGPoint.zero, CGPoint(x: -1440, y: 0), CGPoint(x: 1440, y: 0), CGPoint(x: 0, y: 900), CGPoint(x: 0, y: -900)] {
            for scale in [CGFloat(1), 2] {
                let screen = CGRect(origin: origin, size: CGSize(width: 1440, height: 900))
                let usable = ShelfGeometry.usable(frame: screen, visible: screen, menuHeight: 24, safeTop: 38)
                for base in ScreenshotShelfLayout.frames(visible: usable, screen: screen, sizes: Array(repeating: CGSize(width: 136, height: 104), count: 6)) {
                    let viewport = base.insetBy(dx: -8, dy: -8).intersection(usable)
                    for closing in [false, true] {
                        for step in 0...100 {
                            let motion = ShelfMotion.sample(CGFloat(step) / 100, closing: closing, distance: 180, reduceMotion: false)
                            let visible = base.offsetBy(dx: 0, dy: motion.offset).intersection(viewport)
                            if !visible.isNull { XCTAssertTrue(usable.contains(visible)); XCTAssertTrue(screen.contains(visible)) }
                            XCTAssertEqual(viewport.width * scale / scale, viewport.width, accuracy: 0.0001)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(ShelfMotion.duration, 0.82); XCTAssertEqual(ShelfMotion.closingDuration, 0.58)
        let start = ShelfMotion.sample(0.001, closing: true, distance: 180, reduceMotion: false).offset
        XCTAssertLessThan(start, 0.002)
    }

    func testClickEditsSameItemWithoutClipboardAndNoResurrection() throws {
        _ = NSApplication.shared
        let shelf = ScreenshotShelfController(), id = UUID()
        shelf.setEnabled(true); defer { shelf.setEnabled(false) }
        shelf.add(id: id, image: image()); shelf.show()
        let card = try XCTUnwrap(NSApp.windows.compactMap { $0.shelfTestContent as? ShelfCard }.first { $0.item.id == id })
        let count = NSPasteboard.general.changeCount
        var edits = 0
        shelf.onEdit = { itemID, _ in XCTAssertEqual(itemID, id); edits += 1 }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: card.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        card.mouseDown(with: event); card.mouseUp(with: event); card.mouseUp(with: event)
        XCTAssertEqual(edits, 1); XCTAssertEqual(NSPasteboard.general.changeCount, count)
        XCTAssertFalse(shelf.visible); XCTAssertEqual(shelf.model.items.map(\.id), [id])
        shelf.remove(id); shelf.edit(id); XCTAssertEqual(edits, 1)
    }

    func testProductionLayerRenderedPivotRemainsFixed() throws {
        _ = NSApplication.shared
        let shelf = ScreenshotShelfController(), id = UUID()
        shelf.setEnabled(true); defer { shelf.setEnabled(false) }
        shelf.add(id: id, image: image()); shelf.show()
        shelf.advanceMotion(now: ProcessInfo.processInfo.systemUptime + 1)
        let card = try XCTUnwrap(NSApp.windows.compactMap { $0.shelfTestContent as? ShelfCard }.first { $0.item.id == id })
        card.reduceMotionOverride = false; card.layoutSubtreeIfNeeded()
        let layer = try XCTUnwrap(card.layer), parent = try XCTUnwrap(card.superview?.layer)
        card.configurePivot()
        let pivot = ShelfGeometry.pivot(card.decorationBounds)
        let expected = layer.convert(pivot, to: parent)
        for angle in [CGFloat(-0.02), 0, 0.02] {
            card.setFlex(angle, scale: 1.03)
            let point = layer.convert(pivot, to: parent)
            XCTAssertEqual(point.x, expected.x, accuracy: 0.001); XCTAssertEqual(point.y, expected.y, accuracy: 0.001)
            let bitmap = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
            card.cacheDisplay(in: card.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        }
    }
    func testCentralNotchFallbackAndSuppressionAcrossNegativeScreens() {
        for screen in [CGRect(x: -1600, y: -200, width: 1600, height: 1000), CGRect(x: 100, y: 900, width: 200, height: 600)] {
            let left = CGRect(x: screen.minX, y: screen.maxY - 32, width: screen.width / 2 - 40, height: 32)
            let right = CGRect(x: screen.midX + 40, y: screen.maxY - 32, width: screen.width / 2 - 40, height: 32)
            for notch in [false, true] {
                let r = ShelfGeometry.hotRect(frame: screen, menuHeight: 24, safeTop: notch ? 32 : 0, left: left, right: right)
                XCTAssertEqual(r.midX, screen.midX)
                XCTAssertTrue(screen.contains(r)); XCTAssertLessThan(r.width, screen.width)
                XCTAssertTrue(ShelfGeometry.topHit(CGPoint(x: screen.midX, y: screen.maxY), frame: screen, menuHeight: 24, safeTop: notch ? 32 : 0, left: left, right: right))
                XCTAssertFalse(r.contains(CGPoint(x: screen.minX + 1, y: screen.maxY - 1)))
                XCTAssertFalse(r.contains(CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)))
                XCTAssertEqual(r.width, notch ? 160 : min(300, screen.width * 0.8))
            }
            var state = ShelfHoverState(); state.reset()
            let side = CGPoint(x: screen.minX + 1, y: screen.maxY - 1)
            _ = state.step(now: 0, top: ShelfGeometry.topHit(side, frame: screen, menuHeight: 24), inside: false, visible: false)
            XCTAssertFalse(state.blocked)
            _ = state.step(now: 1, top: true, inside: false, visible: false)
            XCTAssertEqual(state.step(now: 1.13, top: true, inside: false, visible: false), .open)
        }
    }
    func testProductionClipAnchorAndSynchronizedMotionSamples() throws {
        _ = NSApplication.shared
        let shelf = ScreenshotShelfController(), id = UUID()
        shelf.setEnabled(true); defer { shelf.setEnabled(false) }
        shelf.add(id: id, image: image()); shelf.show()
        let card = try XCTUnwrap(NSApp.windows.compactMap { $0.shelfTestContent as? ShelfCard }.first { $0.item.id == id })
        let window = try XCTUnwrap(card.window)
        let rope = try XCTUnwrap(NSApp.windows.first { CGWindowID(exactly: $0.windowNumber).map(shelf.windowIDs.contains) == true && !($0.shelfTestContent is ShelfCard) })
        window.title = "夹点同步-\(id)"; XCTAssertEqual(window.title, "夹点同步-\(id)")
        card.layoutSubtreeIfNeeded()
        let pivot = ShelfGeometry.pivot(card.decorationBounds), layer = try XCTUnwrap(card.layer)
        XCTAssertEqual(layer.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(layer.position.x, card.frame.midX, accuracy: 0.001)
        XCTAssertEqual(layer.position.y, card.frame.midY, accuracy: 0.001)
        XCTAssertTrue(ShelfGeometry.clip(card.decorationBounds).contains(pivot))
        let now = ProcessInfo.processInfo.systemUptime
        func checkAttached() {
            let point = window.convertPoint(toScreen: card.convert(pivot, to: nil))
            XCTAssertTrue(window.screen!.frame.contains(window.frame))
            let fixed = card.layer!.convert(pivot, to: card.superview!.layer)
            XCTAssertEqual(fixed.x, card.frame.minX + pivot.x, accuracy: 0.01)
            XCTAssertEqual(fixed.y, card.frame.minY + pivot.y, accuracy: 0.01)
            XCTAssertTrue(point.x.isFinite)
            XCTAssertEqual(rope.alphaValue, 1)
            XCTAssertNil(rope.contentView?.layer?.animation(forKey: "opacity"))
        }
        for t in [0.0, 0.15, 0.35, 0.6, 0.85, 1.0] {
            shelf.advanceMotion(now: now + t * ShelfMotion.duration)
            checkAttached()
        }
        shelf.beginClosing(now: now + 2, reduceMotion: false)
        for t in [0.0, 0.15, 0.35, 0.6, 0.85, 0.99] {
            shelf.advanceMotion(now: now + 2 + t * ShelfMotion.closingDuration)
            checkAttached(); XCTAssertFalse(shelf.windowIDs.isEmpty)
        }
        shelf.advanceMotion(now: now + 3)
        XCTAssertTrue(shelf.windowIDs.isEmpty)
    }
    func testFlexFixedPivotReducedMotionAndDragFreeze() throws {
        _ = NSApplication.shared
        let shelf = ScreenshotShelfController(), id = UUID()
        shelf.setEnabled(true); defer { shelf.setEnabled(false) }
        shelf.add(id: id, image: image()); shelf.show()
        let card = try XCTUnwrap(NSApp.windows.compactMap { $0.shelfTestContent as? ShelfCard }.first { $0.item.id == id })
        let window = try XCTUnwrap(card.window)
        card.reduceMotionOverride = false
        for closing in [false, true] {
            for t in [CGFloat(0), 0.15, 0.4, 0.7, 1] {
                let sample = ShelfMotion.sample(t, closing: closing, distance: 180, reduceMotion: false)
                card.setFlex(sample.flex)
                let transform = try XCTUnwrap(card.layer?.transform)
                XCTAssertTrue(transform.m41.isFinite); XCTAssertTrue(transform.m42.isFinite)
                XCTAssertLessThan(abs(transform.m21), 0.04)
                let reduced = ShelfMotion.sample(t, closing: closing, distance: 180, reduceMotion: true)
                XCTAssertEqual(reduced.flex, 0); XCTAssertEqual(reduced.offset, closing ? 180 : 0)
            }
        }
        card.setFlex(0.02)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: card.photoRect.midX, y: card.photoRect.midY), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let frame = window.frame
        card.mouseDown(with: event)
        let frozen = card.layer?.transform
        let lifted = card.liftedPhotoRect
        shelf.advanceMotion(now: ProcessInfo.processInfo.systemUptime + 2)
        XCTAssertEqual(window.frame, frame); XCTAssertEqual(card.liftedPhotoRect, lifted)
        card.reduceMotionOverride = true
        XCTAssertEqual(card.layer?.transform.m21, frozen?.m21) // 按下时不改冻结的几何
        shelf.suspended = true
        XCTAssertTrue(shelf.windowIDs.isEmpty)
        XCTAssertTrue(card.layer?.animationKeys()?.isEmpty ?? true)
    }
    func testProductionCardAcceptsFirstMouseWithoutKeyWindow() throws {
        _ = NSApplication.shared
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let shelf = ScreenshotShelfController(), id = UUID()
        shelf.setEnabled(true); defer { shelf.setEnabled(false) }
        shelf.add(id: id, image: image()); shelf.show()
        let window = try XCTUnwrap(NSApp.windows.first {
            !before.contains(ObjectIdentifier($0)) && ($0.shelfTestContent as? ShelfCard)?.item.id == id
        })
        window.title = "首点回归-\(id)"
        XCTAssertEqual(window.title, "首点回归-\(id)")
        let card = try XCTUnwrap(window.shelfTestContent as? ShelfCard)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(card.acceptsFirstResponder)
        XCTAssertTrue(card.acceptsFirstMouse(for: nil))
        XCTAssertFalse(card.needsPanelToBecomeKey)
        let point = card.convert(CGPoint(x: card.photoRect.midX, y: card.photoRect.midY), to: card.superview)
        XCTAssertTrue(card.hitTest(point) === card)
        XCTAssertTrue(try XCTUnwrap(card.hitTest(point)).acceptsFirstMouse(for: nil))
        XCTAssertTrue(try XCTUnwrap(window as? NSPanel).becomesKeyOnlyIfNeeded)
    }
    func testFirstDownDragFromNonKeyProductionWindowStartsNativeSession() throws {
        _ = NSApplication.shared
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let shelf = ScreenshotShelfController(), id = UUID()
        shelf.setEnabled(true); defer { shelf.setEnabled(false) }
        shelf.add(id: id, image: image()); shelf.show()
        let window = try XCTUnwrap(NSApp.windows.first {
            !before.contains(ObjectIdentifier($0)) && ($0.shelfTestContent as? ShelfCard)?.item.id == id
        })
        window.title = "首次拖动-\(id)"
        shelf.advanceMotion(now: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertEqual(window.title, "首次拖动-\(id)")
        let card = try XCTUnwrap(window.shelfTestContent as? ShelfCard)
        let key = NSApp.keyWindow, active = NSApp.isActive
        card.reduceMotionOverride = false
        card.mouseEntered(with: NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        card.layer?.removeAllAnimations()
        XCTAssertFalse(window.isKeyWindow)
        let origin = card.convert(CGPoint(x: card.photoRect.midX, y: card.photoRect.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: origin.x + dx, y: origin.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        var copies = 0
        card.copyAction = { copies += 1 }
        window.sendEvent(event(.leftMouseDown, 0))
        XCTAssertNil(card.activeSession); XCTAssertEqual(copies, 0)
        window.sendEvent(event(.leftMouseDragged, 4))
        XCTAssertNil(card.activeSession); XCTAssertEqual(copies, 0)
        window.sendEvent(event(.leftMouseDragged, 8))
        let session = try XCTUnwrap(card.activeSession)
        XCTAssertEqual(copies, 0)
        window.sendEvent(event(.leftMouseDragged, 12))
        XCTAssertTrue(card.activeSession === session)
        XCTAssertTrue(card.hitTest(card.convert(origin, from: nil)) === card)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === key); XCTAssertEqual(NSApp.isActive, active)
        // 原生 session 已由真实生产 mouseDragged 创建；完成回调仅用于测试清理。
        var endFrame: CGRect?
        card.dragFinished = { _, _, _, _, frame in endFrame = frame }
        let endPoint = CGPoint(x: -500, y: 300)
        card.draggingSession(session, endedAt: endPoint, operation: [])
        let frame = try XCTUnwrap(endFrame)
        XCTAssertEqual(frame.size, card.liftedPhotoRect.size)
        XCTAssertEqual(frame.width, card.photoRect.width * 1.03, accuracy: 0.5)
        XCTAssertEqual(frame.minX + card.photoRect.midX - card.liftedPhotoRect.minX, endPoint.x, accuracy: 0.001)
        XCTAssertEqual(frame.minY + card.photoRect.midY - card.liftedPhotoRect.minY, endPoint.y, accuracy: 0.001)
        window.sendEvent(event(.leftMouseUp, 8))
        // sendEvent / 手动委托完成不会终止 AppKit 的延迟 tracking。
        // 只向本测试进程队列投递取消及松手，排空原生 tracking，避免污染后续控件测试。
        let escape = NSEvent.keyEvent(with: .keyDown, location: origin, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        NSApp.postEvent(escape, atStart: false)
        NSApp.postEvent(event(.leftMouseUp, 8), atStart: false)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(copies, 0)
        XCTAssertNil(card.activeSession)
    }
    func testFirstClickCopiesOnceAndOrphanMouseUpDoesNotCopy() throws {
        _ = NSApplication.shared
        let shelf = ScreenshotShelfController(), id = UUID()
        shelf.setEnabled(true); defer { shelf.setEnabled(false) }
        shelf.add(id: id, image: image()); shelf.show()
        shelf.advanceMotion(now: ProcessInfo.processInfo.systemUptime + 1)
        let card = try XCTUnwrap(NSApp.windows.compactMap { $0.shelfTestContent as? ShelfCard }.first { $0.item.id == id })
        let window = try XCTUnwrap(card.window)
        let origin = card.convert(CGPoint(x: card.photoRect.midX, y: card.photoRect.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ dx: CGFloat = 0) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: origin.x + dx, y: origin.y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        var copies = 0, starts = 0
        card.copyAction = { copies += 1 }
        card.dragStarted = { starts += 1; return nil }
        XCTAssertFalse(window.isKeyWindow)
        window.sendEvent(event(.leftMouseDown))
        window.sendEvent(event(.leftMouseDragged, 3))
        XCTAssertEqual(copies, 0); XCTAssertEqual(starts, 0)
        window.sendEvent(event(.leftMouseUp, 3))
        XCTAssertEqual(copies, 1); XCTAssertEqual(starts, 0)
        card.mouseUp(with: event(.leftMouseUp))
        XCTAssertEqual(copies, 1)
    }
    func testShelfDropUsesOriginalImageSizeInsteadOfThumbnailSize() throws {
        _ = NSApplication.shared
        let point = CGPoint(x: -1200, y: 930), anchor = CGPoint(x: 17, y: 9)
        let frame = ShelfDragGeometry.frame(point: point, anchor: anchor, size: CGSize(width: 136, height: 6.8))
        XCTAssertEqual(frame.minX + anchor.x, point.x)
        XCTAssertEqual(frame.minY + anchor.y, point.y)
        let shelf = ScreenshotShelfController(), id = UUID()
        shelf.setEnabled(true); defer { shelf.setEnabled(false) }
        shelf.add(id: id, image: image())
        let token = try XCTUnwrap(shelf.beginDrag(id))
        XCTAssertNil(shelf.beginDrag(id))
        var received: CGRect?
        shelf.onPin = { image, displayFrame in
            received = displayFrame
            let pin = PinWindowController(image: image)
            pin.show(displayFrame: displayFrame)
            let visibleFrame = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
            let expected = PinWindowController.initialFrame(imageSize: image.size, visibleFrame: visibleFrame, near: frame)
            XCTAssertEqual(pin.window!.frame.origin.x, expected.origin.x, accuracy: 1)
            XCTAssertEqual(pin.window!.frame.origin.y, expected.origin.y, accuracy: 1)
            XCTAssertEqual(pin.window!.frame.width, expected.width, accuracy: 1)
            XCTAssertEqual(pin.window!.frame.height, expected.height, accuracy: 1)
            XCTAssertGreaterThan(pin.window!.frame.width, frame.width)
            XCTAssertGreaterThan(pin.window!.frame.height, frame.height)
            XCTAssertEqual(image.representations.first?.pixelsWide, 640)
            pin.close(); XCTAssertNil(pin.image); XCTAssertNil(pin.window)
            return true
        }
        shelf.finishDrag(id: id, token: token, point: point, operation: [], cancelled: false, displayFrame: frame)
        XCTAssertEqual(received, frame); XCTAssertTrue(shelf.model.items.isEmpty)
    }
    func testReflowReusesSurvivorAndSuspensionRejectsLateCompletion() throws {
        _ = NSApplication.shared
        let shelf = ScreenshotShelfController(), first = UUID(), second = UUID()
        shelf.setEnabled(true); defer { shelf.setEnabled(false) }
        shelf.add(id: first, image: image()); shelf.add(id: second, image: image()); shelf.show()
        let card = try XCTUnwrap(NSApp.windows.compactMap { $0.shelfTestContent as? ShelfCard }.first { $0.item.id == second })
        let window = card.window
        shelf.remove(first)
        XCTAssertTrue(card.window === window)
        XCTAssertTrue(shelf.visible)
        let token = try XCTUnwrap(shelf.beginDrag(second))
        shelf.onPin = { _, _ in XCTFail("暂停后不允许迟到贴图"); return true }
        shelf.suspended = true
        shelf.finishDrag(id: second, token: token, point: .zero, operation: .copy, cancelled: false)
        XCTAssertEqual(shelf.model.items.count, 1)
        XCTAssertTrue(shelf.windowIDs.isEmpty)
        XCTAssertTrue(card.layer?.animationKeys()?.isEmpty ?? true)
        XCTAssertEqual(ShelfDragGeometry.duration(reduceMotion: true), 0)
        XCTAssertGreaterThan(ShelfDragGeometry.duration(reduceMotion: false), 0)
    }
    func testDragOutcomesTokensAndTombstones() throws {
        _ = NSApplication.shared
        for outcome in ["accepted", "outside", "inside", "escape", "failure", "clear", "disabled", "hidden"] {
            let shelf = ScreenshotShelfController(), id = UUID()
            shelf.setEnabled(true); shelf.add(id: id, image: image()); shelf.show()
            let token = try XCTUnwrap(shelf.beginDrag(id))
            var pins = 0
            shelf.onPin = { _, _ in pins += 1; return outcome != "failure" }
            let source = try XCTUnwrap(NSApp.windows.first { ($0.shelfTestContent as? ShelfCard)?.item.id == id })
            let point = outcome == "inside" ? CGPoint(x: source.frame.midX, y: source.frame.midY) : CGPoint(x: 100, y: -10000)
            if outcome == "clear" { shelf.clear() }
            if outcome == "disabled" { shelf.setEnabled(false) }
            if outcome == "hidden" { shelf.hide() }
            shelf.finishDrag(id: id, token: token, point: point, operation: outcome == "accepted" ? .copy : [], cancelled: outcome == "escape")
            XCTAssertEqual(pins, ["outside", "failure"].contains(outcome) ? 1 : 0, outcome)
            let removed = ["accepted", "outside", "clear", "disabled"].contains(outcome)
            XCTAssertEqual(shelf.model.items.isEmpty, removed, outcome)
            shelf.finishDrag(id: id, token: token, point: point, operation: .copy, cancelled: false)
            if removed {
                shelf.setEnabled(true); shelf.add(id: id, image: image())
                XCTAssertTrue(shelf.model.items.isEmpty, outcome)
            }
            shelf.setEnabled(false)
        }
    }
    func testPersistentDisableRestartAndMenuShortcut() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SettingsStore(fileURL: url)
        let shelf = ScreenshotShelfController(); shelf.observe(store)
        var settings = store.load(); settings.screenshotShelfEnabled = false; try store.save(settings)
        let restarted = ScreenshotShelfController(); restarted.observe(SettingsStore(fileURL: url))
        restarted.show(); XCTAssertFalse(restarted.enabled); XCTAssertFalse(restarted.isMonitoring)
        settings.screenshotShelfEnabled = true; try store.save(settings)
        XCTAssertTrue(shelf.isMonitoring); shelf.setEnabled(false)
        let coordinator = AppCoordinator(captureService: ScreenCaptureService(), settingsStore: store, postLongScroll: { _, _ in }, onLongImage: nil, enableScrollMonitors: false)
        defer { coordinator.stop() }
        coordinator.configureMenuBar()
        let menu = try XCTUnwrap(coordinator.mainStatusMenu?.items.first { $0.title == "显示截图架" })
        XCTAssertEqual(menu.keyEquivalent, "t"); XCTAssertEqual(menu.keyEquivalentModifierMask, [.control, .option])
    }
    func testPromiseOffersPNGAndRetainedFileURL() throws {
        let png = try ImageEncoding.pngData(from: image())
        let card = ShelfCard(item: .init(id: UUID(), png: png, thumbnail: image()), frame: CGRect(x: 0, y: 0, width: 154, height: 60))
        let provider = try ShelfPromiseProvider(png: png, delegate: card)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([provider]))
        XCTAssertEqual(board.data(forType: .png), png)
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(board.string(forType: .fileURL))))
        XCTAssertEqual(try Data(contentsOf: url), png)
        XCTAssertTrue(provider.writableTypes(for: board).contains(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")))
    }
    private func image(_ color: NSColor = .red) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(color, atX: 0, y: 0)
        let image = NSImage(size: CGSize(width: 640, height: 32)); image.addRepresentation(rep); return image
    }
    func testModelDedupCapacityAndThumbnail() throws {
        let model = ScreenshotShelfModel(), id = UUID()
        let png = try ImageEncoding.pngData(from: image())
        XCTAssertTrue(model.put(id: id, png: png, insert: true))
        XCTAssertTrue(model.put(id: id, png: png, insert: false))
        XCTAssertEqual(model.items.count, 1)
        XCTAssertLessThanOrEqual(model.items[0].thumbnail.size.width, 320)
        for _ in 0..<10 { model.put(id: UUID(), png: png, insert: true) }
        XCTAssertEqual(model.items.count, 6)
        XCTAssertFalse(model.put(id: id, png: png, insert: false))
        XCTAssertFalse(model.put(id: UUID(), png: Data(), insert: true))
        model.clear(); XCTAssertTrue(model.items.isEmpty)
    }
    func testCopyPromiseAndDisabledHaveNoSideEffects() throws {
        let shelf = ScreenshotShelfController(), id = UUID()
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally(); shelf.setEnabled(false) }
        board.setString("保留", forType: .string)
        let count = board.changeCount
        shelf.add(id: id, image: image()); shelf.show()
        XCTAssertFalse(shelf.copy(id, pasteboard: board)); XCTAssertEqual(count, board.changeCount)
        XCTAssertFalse(shelf.visible); XCTAssertFalse(shelf.isMonitoring)
        shelf.setEnabled(true); shelf.add(id: id, image: image())
        XCTAssertTrue(shelf.copy(id, pasteboard: board))
        let item = try XCTUnwrap(shelf.model.items.first)
        XCTAssertEqual(board.data(forType: .png), item.png)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: item.png))
        XCTAssertEqual(decoded.pixelsWide, 640); XCTAssertEqual(decoded.pixelsHigh, 32)
        let card = ShelfCard(item: item, frame: CGRect(x: 0, y: 0, width: 152, height: 156))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        card.filePromiseProvider(NSFilePromiseProvider(), writePromiseTo: url) { XCTAssertNil($0) }
        XCTAssertEqual(try Data(contentsOf: url), item.png)
        shelf.setEnabled(false)
        XCTAssertFalse(shelf.isMonitoring); XCTAssertTrue(shelf.model.items.isEmpty); XCTAssertTrue(shelf.windowIDs.isEmpty)
    }
    func testDebounceCloseFlushAndRemovedNeverReturns() async throws {
        let shelf = ScreenshotShelfController(), id = UUID(); shelf.setEnabled(true)
        defer { shelf.setEnabled(false) }
        shelf.add(id: id, image: image())
        let png = try ImageEncoding.pngData(from: image(.blue))
        var snapshots = 0
        for _ in 0..<30 { shelf.update(id: id) { snapshots += 1; return { png } } }
        shelf.update(id: id, immediate: true) { snapshots += 1; return { png } }
        let finished = expectation(description: "等待串行渲染与去抖")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(snapshots, 1); XCTAssertEqual(shelf.model.items.count, 1)
        XCTAssertEqual(shelf.model.items.first?.png, png)
        shelf.update(id: id) { XCTFail("移除后不应采样"); return nil }
        shelf.remove(id); XCTAssertTrue(shelf.model.items.isEmpty)
    }
    func testLayoutWithinNegativeOriginAndSmallScreens() {
        for screen in [CGRect(x: -1440, y: 40, width: 1440, height: 860), CGRect(x: 0, y: 0, width: 320, height: 200)] {
            let frames = ScreenshotShelfLayout.frames(visible: screen, count: 6)
            XCTAssertEqual(frames.count, 6)
            for frame in frames { XCTAssertTrue(screen.contains(frame)); XCTAssertLessThan(frame.maxY, screen.maxY) }
        }
        XCTAssertTrue(ScreenshotShelfLayout.frames(visible: .zero, count: 6).isEmpty)
    }
    func testSettingsMenuIntegrationAndWindowSafety() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SettingsStore(fileURL: url)
        XCTAssertTrue(store.load().screenshotShelfEnabled)
        let coordinator = AppCoordinator(captureService: ScreenCaptureService(), settingsStore: store, postLongScroll: { _, _ in }, onLongImage: nil, enableScrollMonitors: false)
        defer { coordinator.stop() }
        coordinator.configureMenuBar()
        XCTAssertTrue(coordinator.mainStatusMenu!.items.contains { $0.title == "显示截图架" })
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.edit(image: image())
        let editorWindows = NSApp.windows.filter { !previousWindows.contains(ObjectIdentifier($0)) && $0.title == "截图编辑" }
        XCTAssertEqual(coordinator.screenshotShelf.model.items.count, 1)
        XCTAssertFalse(store.load().autoCopyAfterCapture)
        coordinator.screenshotShelf.show()
        let ids = coordinator.screenshotShelf.windowIDs
        for window in NSApp.windows where CGWindowID(exactly: window.windowNumber).map(ids.contains) == true {
            XCTAssertEqual(window.canBecomeKey, window.shelfTestContent is ShelfCard); XCTAssertFalse(window.canBecomeMain)
            XCTAssertEqual(window.sharingType, .none); XCTAssertEqual(window.animationBehavior, .none)
            XCTAssertFalse(window.isOpaque)
            XCTAssertLessThan(window.frame.height, 200)
            XCTAssertEqual(window.level, .floating)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let windows = ids.map { [kCGWindowNumber as String: $0, kCGWindowOwnerPID as String: pid] as [String: Any] }
        XCTAssertTrue(try ScreenCaptureService.includedWindowIDs(windows, excluding: ids, ownerPID: pid).isEmpty)
        coordinator.screenshotShelf.suspended = true
        XCTAssertFalse(coordinator.screenshotShelf.visible)
        var settings = store.load(); settings.screenshotShelfEnabled = false; try store.save(settings)
        XCTAssertFalse(coordinator.screenshotShelf.enabled); XCTAssertFalse(coordinator.screenshotShelf.isMonitoring)
        // 只关闭测试自行创建的编辑器，不触碰运行中的用户应用。
        editorWindows.forEach { $0.close() }
    }
    func testActualTopAndMenuOnOffsetDisplays() {
        for frame in [CGRect(x: -1920, y: -300, width: 1920, height: 1080), CGRect(x: 100, y: 900, width: 1440, height: 900)] {
            XCTAssertTrue(ShelfGeometry.topHit(CGPoint(x: frame.midX, y: frame.maxY), frame: frame, menuHeight: 24))
            XCTAssertTrue(ShelfGeometry.topHit(CGPoint(x: frame.midX, y: frame.maxY - 20), frame: frame, menuHeight: 24))
            XCTAssertFalse(ShelfGeometry.topHit(CGPoint(x: frame.minX - 1, y: frame.maxY), frame: frame, menuHeight: 24))
            XCTAssertFalse(ShelfGeometry.topHit(CGPoint(x: frame.midX, y: frame.maxY - 5), frame: frame, menuHeight: 4))
            let visible = CGRect(x: frame.minX + 60, y: frame.minY + 80, width: frame.width - 60, height: frame.height - 80)
            let usable = ShelfGeometry.usable(frame: frame, visible: visible, menuHeight: 24, safeTop: 38)
            XCTAssertEqual(usable.maxY, frame.maxY - 38)
            XCTAssertEqual(usable.minX, visible.minX)
            XCTAssertEqual(usable.minY, visible.minY)
        }
    }
    func testDeterministicDwellCancellationAndCardTransit() {
        var state = ShelfHoverState()
        XCTAssertEqual(state.step(now: 0, top: true, inside: false, visible: false), .none)
        XCTAssertEqual(state.step(now: 0.1, top: false, inside: false, visible: false), .none)
        XCTAssertEqual(state.step(now: 1, top: true, inside: false, visible: false), .none)
        XCTAssertEqual(state.step(now: 1.13, top: true, inside: false, visible: false), .open)
        XCTAssertEqual(state.step(now: 2, top: false, inside: true, visible: true), .none)
        XCTAssertEqual(state.step(now: 3, top: false, inside: false, visible: true), .none)
        XCTAssertEqual(state.step(now: 3.1, top: false, inside: true, visible: true), .none)
        XCTAssertNil(state.exited)
        XCTAssertEqual(state.step(now: 4, top: false, inside: false, visible: true), .none)
        XCTAssertEqual(state.step(now: 4.23, top: false, inside: false, visible: true), .none)
        XCTAssertEqual(state.step(now: 4.51, top: false, inside: false, visible: true), .none)
        XCTAssertEqual(state.step(now: 100, top: false, inside: false, visible: true), .none)
        state.reset()
        XCTAssertEqual(state.step(now: 10, top: true, inside: false, visible: false), .none)
        XCTAssertNil(state.entered)
        _ = state.step(now: 11, top: false, inside: false, visible: false)
        _ = state.step(now: 12, top: true, inside: false, visible: false)
        XCTAssertEqual(state.step(now: 12.13, top: true, inside: false, visible: false), .open)
    }
    func testSuspensionAndScreenChangeClearWindows() {
        _ = NSApplication.shared
        let shelf = ScreenshotShelfController(); shelf.setEnabled(true)
        defer { shelf.setEnabled(false) }
        shelf.add(id: UUID(), image: image()); shelf.show()
        shelf.suspended = true
        XCTAssertFalse(shelf.visible); XCTAssertTrue(shelf.windowIDs.isEmpty)
        shelf.show(); XCTAssertFalse(shelf.visible)
        shelf.suspended = false; shelf.show()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertFalse(shelf.visible); XCTAssertTrue(shelf.windowIDs.isEmpty)
    }
    func testHangingGeometryMotionAndButtonHitAreas() throws {
        XCTAssertEqual(ShelfMotion.offsets(reduceMotion: true), [0])
        XCTAssertEqual(ShelfMotion.angles(reduceMotion: true, index: 1), [0])
        XCTAssertEqual(ShelfMotion.offsets(reduceMotion: false).last, 0)
        XCTAssertEqual(ShelfMotion.angles(reduceMotion: false, index: 0).last, 0)
        XCTAssertEqual(ShelfGeometry.sag(0), 0); XCTAssertEqual(ShelfGeometry.sag(0.5, width: 2000), 30)
        let model = ScreenshotShelfModel()
        model.put(id: UUID(), png: try ImageEncoding.pngData(from: image()), insert: true)
        let card = ShelfCard(item: model.items[0], frame: CGRect(x: 0, y: 0, width: 152, height: 156))
        let clip = ShelfGeometry.clip(card.bounds)
        XCTAssertEqual(clip.height, 8)
        card.refreshControls(focused: true)
        XCTAssertFalse(card.subviews.contains { $0 is NSButton })
        let frames = ScreenshotShelfLayout.frames(visible: CGRect(x: 0, y: 0, width: 1200, height: 800), count: 6)
        XCTAssertNotEqual(frames[0].maxY, frames[1].maxY)
    }
    func testFullScreenRopeAttachmentAndAspectSizes() {
        let screen = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        let usable = screen.insetBy(dx: 0, dy: 40)
        let sizes = [CGSize(width: 2000, height: 100), CGSize(width: 100, height: 2000), CGSize(width: 400, height: 300)]
        let frames = ScreenshotShelfLayout.frames(visible: usable, screen: screen, sizes: sizes)
        XCTAssertEqual(frames.count, 3)
        for (size, frame) in zip(sizes, frames) {
            let photo = ShelfGeometry.photoSize(size)
            XCTAssertEqual(photo.width / photo.height, size.width / size.height, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(photo.width, 136); XCTAssertLessThanOrEqual(photo.height, 104)
            let bounds = CGRect(origin: .zero, size: frame.size)
            let pivot = ShelfGeometry.pivot(bounds)
            XCTAssertEqual(frame.minY + pivot.y, ShelfGeometry.ropeY(x: frame.midX, screen: screen, top: usable.maxY), accuracy: 0.001)
            XCTAssertTrue(ShelfGeometry.clip(bounds).contains(pivot))
            XCTAssertTrue(usable.contains(frame))
        }
        XCTAssertNotEqual(frames[0].height, frames[1].height)
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 24, accuracy: 0.001)
    }
    func testBusyAndTopClickSuppression() {
        var state = ShelfHoverState()
        _ = state.step(now: 0, top: false, inside: false, visible: true)
        XCTAssertEqual(state.step(now: 1, top: false, inside: false, visible: true, busy: true), .none)
        XCTAssertNil(state.exited)
        XCTAssertEqual(state.step(now: 2, top: true, inside: false, visible: true, clickedTop: true), .close)
        XCTAssertEqual(state.step(now: 3, top: true, inside: false, visible: false), .none)
        XCTAssertTrue(state.blocked)
        _ = state.step(now: 4, top: false, inside: false, visible: false)
        _ = state.step(now: 5, top: true, inside: false, visible: false)
        XCTAssertEqual(state.step(now: 5.13, top: true, inside: false, visible: false), .open)
    }
    func testExitCompletionCancellationAndReducedMotion() {
        _ = NSApplication.shared
        let shelf = ScreenshotShelfController(); shelf.setEnabled(true)
        defer { shelf.setEnabled(false) }
        shelf.add(id: UUID(), image: image()); shelf.show()
        let ids = shelf.windowIDs; XCTAssertFalse(ids.isEmpty)
        shelf.beginClosing(now: 0, reduceMotion: false)
        XCTAssertFalse(shelf.visible); XCTAssertEqual(shelf.windowIDs, ids)
        shelf.finishClosing(now: 0.19); XCTAssertEqual(shelf.windowIDs, ids)
        shelf.finishClosing(now: ShelfMotion.duration + 0.01); XCTAssertTrue(shelf.windowIDs.isEmpty)
        shelf.show(); shelf.beginClosing(now: 1, reduceMotion: false)
        shelf.show(); let reopened = shelf.windowIDs
        shelf.finishClosing(now: 2); XCTAssertTrue(shelf.visible); XCTAssertEqual(shelf.windowIDs, reopened)
        shelf.beginClosing(now: 3, reduceMotion: true); XCTAssertTrue(shelf.windowIDs.isEmpty)
        shelf.show(); shelf.beginClosing(now: 4, reduceMotion: false); shelf.suspended = true
        XCTAssertTrue(shelf.windowIDs.isEmpty)
        shelf.finishClosing(now: 5); XCTAssertFalse(shelf.visible)
    }
    func testStaticPhotoGeometryAndAccessibilityModes() throws {
        for size in [CGSize(width: 640, height: 32), CGSize(width: 32, height: 640), CGSize(width: 400, height: 300)] {
            let thumbnail = NSImage(size: size)
            let frame = ScreenshotShelfLayout.frames(visible: CGRect(x: 0, y: 0, width: 1200, height: 800), screen: CGRect(x: 0, y: 0, width: 1200, height: 800), sizes: [size])[0]
            let card = ShelfCard(item: .init(id: UUID(), png: Data(), thumbnail: thumbnail), frame: CGRect(origin: .zero, size: frame.size))
            let photo = card.photoRect, pivot = card.layer?.anchorPoint
            XCTAssertEqual(photo.width / photo.height, size.width / size.height, accuracy: 0.0001)
            XCTAssertTrue(card.bounds.contains(card.rimRect))
            XCTAssertFalse(photo.intersects(card.clipJaw))
            for reduced in [false, true] {
                card.reduceTransparencyOverride = reduced
                XCTAssertEqual(card.reducesTransparency, reduced)
                XCTAssertEqual(card.photoRect, photo); XCTAssertEqual(card.layer?.anchorPoint, pivot)
                card.refreshControls(focused: true)
                XCTAssertEqual(card.glass.reducesTransparency, reduced)
                XCTAssertNotNil(card.glass.layer?.mask)
            }
            XCTAssertEqual(card.layer?.cornerRadius, 0); XCTAssertFalse(card.layer?.masksToBounds ?? true)
        }
    }
    func testHoverPivotIndependentMotionAndStableWindow() throws {
        _ = NSApplication.shared
        let shelf = ScreenshotShelfController(), id = UUID()
        shelf.setEnabled(true); defer { shelf.setEnabled(false) }
        shelf.add(id: id, image: image()); shelf.show()
        let card = try XCTUnwrap(NSApp.windows.compactMap { $0.shelfTestContent as? ShelfCard }.first { $0.item.id == id })
        let window = try XCTUnwrap(card.window), frame = window.frame, ids = shelf.windowIDs
        window.title = "摆动回归-\(id)"
        let pivot = card.layer!.position, anchor = card.layer!.anchorPoint, png = card.item.png
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        card.reduceMotionOverride = false
        for _ in 0..<4 {
            card.mouseEntered(with: event)
            XCTAssertEqual(card.hoverScale, 1.03)
            XCTAssertNotNil(card.layer?.animation(forKey: "hoverScale"))
            XCTAssertNil(card.layer?.animation(forKey: "transform.rotation.z"))
            XCTAssertEqual(card.layer?.position, pivot); XCTAssertEqual(card.layer?.anchorPoint, anchor)
            card.mouseExited(with: event); XCTAssertEqual(card.hoverScale, 1)
        }
        XCTAssertEqual(window.title, "摆动回归-\(id)")
        XCTAssertEqual(window.frame, frame); XCTAssertEqual(shelf.windowIDs, ids)
        XCTAssertEqual(card.item.png, png)
        card.mouseEntered(with: event); card.reduceMotionOverride = true
        XCTAssertEqual(card.hoverScale, 1)
        XCTAssertTrue(card.layer?.animationKeys()?.isEmpty ?? true)
        XCTAssertEqual(card.glass.layer?.borderWidth, 1)
        card.reduceTransparencyOverride = true; XCTAssertTrue(card.glass.reducesTransparency)
    }
    func testOutsideDownOnlyRemainingSurvivesAndMonitorsCleanUp() throws {
        _ = NSApplication.shared
        let shelf = ScreenshotShelfController(), first = UUID(), second = UUID()
        shelf.setEnabled(true); defer { shelf.setEnabled(false) }
        shelf.add(id: first, image: image()); shelf.add(id: second, image: image()); shelf.show()
        let card = try XCTUnwrap(NSApp.windows.compactMap { $0.shelfTestContent as? ShelfCard }.first { $0.item.id == second })
        let window = try XCTUnwrap(card.window)
        window.title = "保活-\(second)"
        let inside = window.convertPoint(toScreen: CGPoint(x: card.photoRect.midX, y: card.photoRect.midY))
        let outside = CGPoint(x: -10000, y: -10000)
        shelf.handleOutsideEvent(type: .leftMouseDown, point: inside); XCTAssertTrue(shelf.visible)
        let token = try XCTUnwrap(shelf.beginDrag(first))
        shelf.handleOutsideEvent(type: .leftMouseDown, point: outside); XCTAssertTrue(shelf.visible)
        shelf.finishDrag(id: first, token: token, point: outside, operation: .copy, cancelled: false)
        shelf.handleOutsideEvent(type: .leftMouseUp, point: outside)
        XCTAssertTrue(shelf.visible); XCTAssertTrue(card.window === window); XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.title, "保活-\(second)")
        shelf.handleOutsideEvent(type: .leftMouseDown, point: outside)
        XCTAssertFalse(shelf.visible); XCTAssertFalse(shelf.hasMouseMonitors)
        shelf.show(); XCTAssertTrue(shelf.hasMouseMonitors)
        shelf.suspended = true; XCTAssertFalse(shelf.hasMouseMonitors)
        shelf.suspended = false; shelf.show()
        let last = try XCTUnwrap(shelf.beginDrag(second))
        shelf.finishDrag(id: second, token: last, point: outside, operation: .copy, cancelled: false)
        XCTAssertFalse(shelf.visible); XCTAssertTrue(shelf.windowIDs.isEmpty)
        XCTAssertFalse(shelf.hasMouseMonitors)
        shelf.setEnabled(false); XCTAssertFalse(shelf.isMonitoring)
    }
    func testCornerRevealFocusActionsAndTransparentHitTesting() throws {
        _ = NSApplication.shared
        let card = ShelfCard(item: .init(id: UUID(), png: Data(), thumbnail: image()), frame: CGRect(x: 0, y: 0, width: 154, height: 100))
        let point = CGPoint(x: 1, y: 1)
        XCTAssertFalse(card.controlsVisible); XCTAssertNil(card.hitTest(point))
        XCTAssertNil(card.hitTest(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(card.hitTest(CGPoint(x: card.photoRect.midX, y: card.photoRect.midY)) === card)
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        card.mouseEntered(with: event)
        XCTAssertTrue(card.controlsVisible); XCTAssertNil(card.hitTest(point))
        var copied = 0
        card.copyAction = { copied += 1 }
        card.mouseDown(with: event); card.mouseUp(with: event)
        XCTAssertEqual(copied, 1)
        card.mouseExited(with: event); XCTAssertFalse(card.controlsVisible)
        XCTAssertTrue(card.becomeFirstResponder()); XCTAssertTrue(card.controlsVisible)
        card.refreshControls(focused: false); XCTAssertFalse(card.controlsVisible)
        XCTAssertNil(card.hitTest(point))
        XCTAssertTrue(card.acceptsFirstResponder)
    }
    func testOffscreenPhotoCornersRemainUnclipped() throws {
        let thumbnail = NSImage(size: CGSize(width: 80, height: 60), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let card = ShelfCard(item: .init(id: UUID(), png: Data(), thumbnail: thumbnail), frame: CGRect(x: 0, y: 0, width: 118, height: 128))
        card.reduceTransparencyOverride = true
        let rep = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
        card.cacheDisplay(in: card.bounds, to: rep)
        let photo = card.photoRect
        let sx = CGFloat(rep.pixelsWide) / card.bounds.width
        let sy = CGFloat(rep.pixelsHigh) / card.bounds.height
        let center = try XCTUnwrap(rep.colorAt(x: Int(photo.midX * sx), y: Int((card.bounds.height - photo.midY) * sy))?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.redComponent, 0.9)
        for x in [photo.minX + 1, photo.maxX - 2] {
            for y in [photo.minY + 1, photo.maxY - 2] {
                let color = try XCTUnwrap(rep.colorAt(x: Int(x * sx), y: Int((card.bounds.height - y) * sy) - 1)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(color.redComponent, center.redComponent, accuracy: 0.01)
                XCTAssertEqual(color.greenComponent, center.greenComponent, accuracy: 0.01)
                XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01)
            }
        }
        XCTAssertEqual(rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01)
    }

    func testDecorationClippingAndFocusDoNotChangePhotoOrRootOpacity() throws {
        let thumbnail = NSImage(size: CGSize(width: 80, height: 60), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let card = ShelfCard(item: .init(id: UUID(), png: Data(), thumbnail: thumbnail), frame: CGRect(x: 0, y: 0, width: 118, height: 128))
        let photo = card.photoRect
        for reduced in [false, true] {
            card.reduceTransparencyOverride = reduced
            for focused in [false, true] {
                card.refreshControls(focused: focused)
                XCTAssertEqual(card.controlsVisible, focused)
                XCTAssertEqual(card.alphaValue, 1)
                XCTAssertFalse(card.isOpaque)
                XCTAssertEqual(card.layer?.shadowOpacity, 0)
                XCTAssertEqual(card.photoRect, photo)
                let rep = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
                card.cacheDisplay(in: card.bounds, to: rep)
                let sx = CGFloat(rep.pixelsWide) / card.bounds.width
                let sy = CGFloat(rep.pixelsHigh) / card.bounds.height
                // 照片中线两侧的装饰外部必须透明，不能残留矩形面板或重复描边。
                for x in [card.rimRect.minX - 1, card.rimRect.maxX + 1] {
                    XCTAssertEqual(rep.colorAt(x: Int(x * sx), y: Int((card.bounds.height - photo.midY) * sy))?.alphaComponent ?? 1, 0, accuracy: 0.01)
                }
                XCTAssertFalse(card.subviews.contains { $0 is NSButton })
            }
        }
    }
}
