import AppKit
import XCTest
@testable import 截图Free

@MainActor
final class WindowDecorationRegressionTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testSettingsTitleBlankHitAndControls() throws {
        _ = NSApplication.shared
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = SettingsWindowController(settingsStore: SettingsStore(fileURL: temporaryURL().appendingPathComponent("settings.json")))
        let created = controller.makeWindow()
        let window = try XCTUnwrap(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.title == "截图Free 设置" })
        XCTAssertTrue(window === created)
        XCTAssertFalse(window.isVisible)
        defer { window.close(); withExtendedLifetime(controller) {} }
        let root = try XCTUnwrap(window.contentView as? GlassView)
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.isMovable)
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertTrue(root.mouseDownCanMoveWindow)
        XCTAssertEqual(root.reducesTransparency, NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        XCTAssertEqual(root.tintOpacity, root.reducesTransparency ? 1 : GlassView.normalTintOpacity)
        let bodyBlank = NSPoint(x: 400, y: 110)
        XCTAssertTrue(root.hitTest(root.convert(bodyBlank, to: root.superview)) === root)
        let blank = NSPoint(x: root.bounds.midX, y: root.bounds.maxY - 8)
        XCTAssertGreaterThan(blank.y, window.contentLayoutRect.maxY)
        XCTAssertTrue(root.hitTest(root.convert(blank, to: root.superview)) === root)
        XCTAssertNil(root.effectView.hitTest(blank))
        let title = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first { $0.stringValue == "设置" })
        let titleFrame = title.convert(title.bounds, to: nil)
        XCTAssertLessThanOrEqual(titleFrame.maxY, window.contentLayoutRect.maxY - 8)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(type))
            let buttonFrame = button.convert(button.bounds, to: nil)
            XCTAssertFalse(titleFrame.intersects(buttonFrame))
            XCTAssertLessThan(titleFrame.maxY, buttonFrame.minY)
            print("Settings layout title=\(titleFrame) trafficLight=\(buttonFrame)")
        }
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor.alphaComponent, 0)
        XCTAssertEqual(root.layer?.backgroundColor?.alpha, GlassView.interactionBackingOpacity)
        XCTAssertEqual(root.alphaValue, 1)
        XCTAssertTrue(root.hitTest(title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: root.superview)) === root)
        let controls = descendants(root).compactMap { $0 as? NSControl }.filter { $0 is NSButton || $0 is NSPopUpButton }
        XCTAssertEqual(controls.count, 6)
        for control in controls {
            let rect = control.convert(control.bounds, to: nil)
            XCTAssertLessThanOrEqual(rect.maxY, titleFrame.minY)
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
            let hit = root.hitTest(control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: root.superview))
            XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true)
            XCTAssertNotNil(control.action)
            XCTAssertTrue(control.isEnabled)
        }
        for view in descendants(root).compactMap({ $0 as? NSTextField }) {
            XCTAssertTrue(root.bounds.contains(view.convert(view.bounds, to: root)))
        }
        print("Settings layout window=\(window.frame.size) safe=\(window.contentLayoutRect) reduceTransparency=\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)")
    }

    func testEditorRoundedMediaShadowAndExportPreservePixels() throws {
        _ = NSApplication.shared
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<30 { for x in 0..<40 {
            bitmap.setColor(NSColor(deviceRed: CGFloat(x) / 39, green: CGFloat(y) / 29, blue: 0.5, alpha: 1), atX: x, y: y)
        } }
        let source = try XCTUnwrap(bitmap.cgImage)
        for zoom in [false, true] {
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            let controller = AnnotationEditorController(image: NSImage(cgImage: source, size: NSSize(width: 40, height: 30)), allowsZoom: zoom)
            controller.show()
            defer { _ = controller.perform(NSSelectorFromString("closeWindow")) }
            let window = try XCTUnwrap(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.title == "截图编辑" })
            let root = try XCTUnwrap(window.contentView)
            let views = descendants(root)
            let canvas = try XCTUnwrap(views.compactMap { $0 as? AnnotationCanvasView }.first)
            XCTAssertFalse(window.isOpaque)
            XCTAssertFalse(window.hasShadow)
            XCTAssertEqual(window.backgroundColor.alphaComponent, 0)
            XCTAssertEqual(root.layer?.backgroundColor?.alpha, 0)
            let display = try XCTUnwrap(views.first { $0 is MediaDisplayView } as? MediaDisplayView)
            XCTAssertEqual(display.layer?.cornerRadius ?? 0, 0, accuracy: 0.001)
            XCTAssertEqual(canvas.layer?.borderWidth, 0)
            XCTAssertEqual(Double(canvas.layer?.shadowOpacity ?? 0), 0, accuracy: 0.001)
            XCTAssertEqual(canvas.layer?.masksToBounds, true)
            for view in views where (view.layer?.cornerRadius ?? 0) > 0 && !(view is GlassView) && !String(describing: type(of: view)).contains("Glass") {
                XCTAssertEqual(view.layer?.masksToBounds, true, "装饰未裁剪：\(type(of: view))")
            }
            let toolbar = try XCTUnwrap(views.compactMap { $0 as? GlassView }.first)
            let media = views.compactMap { $0 as? NSScrollView }.first
            XCTAssertLessThanOrEqual(toolbar.frame.maxY, display.frame.minY)
            if let media {
                XCTAssertFalse(media.drawsBackground)
                XCTAssertFalse(media.contentView.drawsBackground)
                XCTAssertEqual(media.layer?.cornerRadius ?? 0, MediaDisplayView.cornerRadius, accuracy: 0.001)
                XCTAssertEqual(media.layer?.masksToBounds, true)
            }
            XCTAssertEqual(display.layer?.cornerRadius ?? 0, 0, accuracy: 0.001)
            XCTAssertFalse(display.layer?.masksToBounds ?? true)
            XCTAssertEqual(display.layer?.shadowOpacity ?? 0, 0.16, accuracy: 0.001)
            XCTAssertEqual(display.layer?.shadowRadius ?? 0, 10, accuracy: 0.001)
            let output = try XCTUnwrap(ImageEncoding.sourceCGImage(from: canvas.renderedImage()))
            XCTAssertEqual(output.width, source.width)
            XCTAssertEqual(output.height, source.height)
            XCTAssertEqual(output.dataProvider?.data as Data?, source.dataProvider?.data as Data?)
            // 不对画布离屏 alpha 作展示断言：展示裁剪由 MediaDisplayView 负责，
            // 导出链路已通过 output 与 source 的尺寸及字节一致性验证。
        }
    }

    func testTintOffscreenAlphaAndRoundedCorners() throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let glass = GlassView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
            glass.appearance = NSAppearance(named: appearance)
            let tint = try XCTUnwrap(glass.effectView.subviews.first)
            for reduced in [false, true] {
                glass.updateAccessibility(reduceTransparency: reduced)
                XCTAssertEqual(glass.layer?.backgroundColor?.alpha, GlassView.interactionBackingOpacity)
                XCTAssertFalse(glass.isOpaque)
                let rep = try XCTUnwrap(tint.bitmapImageRepForCachingDisplay(in: tint.bounds))
                tint.cacheDisplay(in: tint.bounds, to: rep)
                XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)).alphaComponent,
                               reduced ? 1 : 0.06, accuracy: 0.02)
                for x in [0, rep.pixelsWide - 1] { for y in [0, rep.pixelsHigh - 1] {
                    XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: x, y: y)).alphaComponent, 0, accuracy: 0.01)
                } }
            }
        }
    }
}
