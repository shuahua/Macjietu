import AppKit
import XCTest
@testable import 截图Free

private final class MenuPolishRegistration: ShortcutRegistration {
    func register(shortcut: Shortcut, handler: @escaping () -> Void) {}
    func unregister() {}
    func status(for shortcut: Shortcut) -> ShortcutManager.RegistrationStatus? {
        .init(shortcut: shortcut, isRegistered: true, errorCode: nil)
    }
}

@MainActor
final class SettingsSidebarMenuPolishTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testSixMenuBindingsRebindAndClearImmediatelyWithoutReopening() throws {
        _ = NSApplication.shared
        let store = SettingsStore(fileURL: temporaryURL().appendingPathComponent("settings.json"))
        let coordinator = AppCoordinator(captureService: ScreenCaptureService(), settingsStore: store,
            postLongScroll: { _, _ in }, onLongImage: nil,
            menuPermissions: { .init(screen: true, accessibility: true, microphone: true) },
            enableScrollMonitors: false, shortcutRegistrationFactory: { MenuPolishRegistration() })
        coordinator.configureMenuBar()
        coordinator.shortcutBindings.start()
        defer { coordinator.stop() }
        let menu = try XCTUnwrap(coordinator.mainStatusMenu)
        let selectors = ["startCaptureFromMenu", "startWindowCaptureFromMenu", "startFullScreenCaptureFromMenu",
                         "startAutomaticLongCaptureFromMenu", "startManualLongCaptureFromMenu", "startRecordingFromMenu"]
        func verify(_ action: ShortcutAction, _ shortcut: Shortcut?) throws {
            let index = try XCTUnwrap(ShortcutAction.allCases.firstIndex(of: action))
            let item = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString(selectors[index]) })
            XCTAssertEqual(item.title, action.title)
            XCTAssertTrue(item.target === coordinator)
            XCTAssertEqual(item.keyEquivalent, shortcut?.menuKeyEquivalent ?? "")
            XCTAssertEqual(item.keyEquivalentModifierMask, shortcut?.modifierFlags ?? [])
        }
        for action in ShortcutAction.allCases { try verify(action, action.legacyDefault) }
        for (index, action) in ShortcutAction.allCases.enumerated() {
            XCTAssertNil(coordinator.shortcutBindings.update(nil, for: action))
            try verify(action, nil)
            XCTAssertEqual(coordinator.shortcutBindings.display(for: action), "未设置")
            let first = Shortcut(keyCode: Shortcut.functionKeys[index], modifierFlags: [.control, .option])
            XCTAssertNil(coordinator.shortcutBindings.update(first, for: action))
            try verify(action, first)
            let second = Shortcut(keyCode: Shortcut.functionKeys[index + 6], modifierFlags: [.command, .shift])
            XCTAssertNil(coordinator.shortcutBindings.update(second, for: action))
            try verify(action, second)
            XCTAssertNil(coordinator.shortcutBindings.update(nil, for: action))
            try verify(action, nil)
        }
        coordinator.menuWillOpen(menu)
        for action in ShortcutAction.allCases { try verify(action, nil) }
        XCTAssertEqual(menu.item(withTitle: "设置")?.keyEquivalent, ",")
        XCTAssertEqual(menu.item(withTitle: "退出")?.keyEquivalent, "q")
    }

    func testMenuSpecialKeysAndPhysicalKeyFallback() {
        XCTAssertEqual(Shortcut(keyCode: 17, modifierFlags: .command).menuKeyEquivalent, "t")
        XCTAssertEqual(Shortcut(keyCode: 49, modifierFlags: .option).menuKeyEquivalent, " ")
        XCTAssertEqual(Shortcut(keyCode: 123, modifierFlags: .control).menuKeyEquivalent, String(UnicodeScalar(0xF702)!))
        XCTAssertNil(Shortcut(keyCode: 82, modifierFlags: .command).menuKeyEquivalent)
        XCTAssertEqual(Shortcut(keyCode: 82, modifierFlags: .command).displayString, "⌘小键盘 0")
    }

    func testSidebarFocusAndLabelImageGeometryDoNotAccumulate() throws {
        _ = NSApplication.shared
        let button = GlassButton(title: "通用", target: nil, action: nil)
        button.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.useSidebarSurface()
        button.frame = NSRect(x: 0, y: 0, width: 136, height: 36)
        let cell = try XCTUnwrap(button.cell as? NSButtonCell)
        let titleRect = cell.titleRect(forBounds: button.bounds)
        let imageRect = cell.imageRect(forBounds: button.bounds)
        for state in [NSControl.StateValue.on, .off, .on, .off] {
            button.state = state
            button.setHovered(true)
            XCTAssertTrue(button.becomeFirstResponder())
            XCTAssertTrue(button.focused)
            button.highlight(true)
            XCTAssertEqual(cell.titleRect(forBounds: button.bounds), titleRect)
            XCTAssertEqual(cell.imageRect(forBounds: button.bounds), imageRect)
            button.highlight(false)
            button.setHovered(false)
            XCTAssertTrue(button.resignFirstResponder())
            XCTAssertFalse(button.focused)
            XCTAssertEqual(button.focusRingType, .none)
            XCTAssertFalse(button.hasFeedbackAnimation)
            XCTAssertEqual(cell.titleRect(forBounds: button.bounds), titleRect)
        }
    }

    func testDividerPixelsRespectAppearanceAndOpaqueMode() throws {
        _ = NSApplication.shared
        let divider = SettingsSidebarDivider(frame: NSRect(x: 0, y: 0, width: 1, height: 80))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            divider.appearance = NSAppearance(named: appearance)
            for opaque in [false, true] {
                divider.reduceTransparencyOverride = opaque
                let rep = try XCTUnwrap(divider.bitmapImageRepForCachingDisplay(in: divider.bounds))
                divider.cacheDisplay(in: divider.bounds, to: rep)
                let color = try XCTUnwrap(rep.colorAt(x: 0, y: rep.pixelsHigh / 2))
                XCTAssertGreaterThan(color.alphaComponent, 0)
                if opaque { XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01) }
                else { XCTAssertLessThan(color.alphaComponent, 1) }
            }
        }
    }

    func testDividerAndSidebarGeometryHitsAcrossBackendsAndStates() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController(settingsStore: SettingsStore(fileURL: temporaryURL().appendingPathComponent("settings.json")))
        let window = controller.makeWindow()
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView as? GlassView)
        let divider = try XCTUnwrap(descendants(root).compactMap { $0 as? SettingsSidebarDivider }.first)
        let detail = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "settings-detail" })
        let buttons = descendants(root).compactMap { $0 as? GlassButton }.filter(\.usesSidebarSurface)
        XCTAssertEqual(buttons.count, 3)
        let frames = buttons.map(\.frame)
        for (index, button) in buttons.enumerated() {
            XCTAssertEqual(button.tag, index)
            XCTAssertTrue(button.target === controller)
            XCTAssertEqual(button.action, NSSelectorFromString("categoryClicked:"))
            button.performClick(nil)
            XCTAssertEqual(controller.selectedCategory, SettingsWindowController.Category.allCases[index])
        }
        for mode in [0, 1, 2, 0] {
            root.forceFallback = mode == 1
            root.updateAccessibility(reduceTransparency: mode == 2)
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(divider.frame.width, 1)
            XCTAssertEqual(divider.frame.minY, 20)
            XCTAssertLessThan(divider.frame.maxY, divider.superview!.bounds.maxY - 20)
            XCTAssertLessThan(divider.frame.maxX, detail.frame.minX)
            XCTAssertNil(divider.hitTest(divider.frame.origin))
            XCTAssertTrue(root.hitTest(divider.convert(NSPoint(x: 0.5, y: 100), to: root.superview)) === root)
            for category in SettingsWindowController.Category.allCases {
                controller.selectCategory(category)
                for button in buttons {
                    XCTAssertLessThan(button.frame.maxX, divider.frame.minX)
                    for hovered in [true, false] {
                        button.setHovered(hovered)
                        for pressed in [true, false] {
                            button.highlight(pressed)
                            button.layoutSubtreeIfNeeded()
                            XCTAssertEqual(buttons.map(\.frame), frames)
                            for point in [NSPoint(x: 1, y: 18), NSPoint(x: 68, y: 18), NSPoint(x: 135, y: 18)] {
                                XCTAssertTrue(root.hitTest(button.convert(point, to: root.superview)) === button)
                            }
                        }
                    }
                }
                let detailFrame = detail.convert(detail.bounds, to: root)
                for control in descendants(detail).compactMap({ $0 as? NSControl }) {
                    XCTAssertTrue(detailFrame.contains(control.convert(control.bounds, to: root)))
                }
            }
            XCTAssertEqual(root.layer?.backgroundColor?.alpha, 0.02)
        }
    }

    /// 单一 bounds 圆角底形，不能叠加原生 bezel 或 inset 反馈底形。
    func testSidebarOffscreenPixelsSingleContourAndNoResidualFeedback() throws {
        _ = NSApplication.shared
        let button = GlassButton(title: "", target: nil, action: nil)
        button.useSidebarSurface()
        button.frame = NSRect(x: 0, y: 0, width: 136, height: 36)
        button.reduceMotionOverride = true
        XCTAssertTrue(button.layer?.sublayers?.first?.isHidden == true, "侧栏不得叠加普通按钮 inset 反馈层")
        func render() throws -> NSBitmapImageRep {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 136, pixelsHigh: 36,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                button.cell?.draw(withFrame: button.bounds, in: button)
            }
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> CGFloat {
            try XCTUnwrap(rep.colorAt(x: x, y: y)).alphaComponent
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            button.appearance = NSAppearance(named: appearance)
            for opaque in [false, true] {
                button.reduceTransparencyOverride = opaque
                button.state = .off
                let baseline = try render()
                for selected in [true, false, true] {
                    button.state = selected ? .on : .off
                    for hovered in [false, true, false] {
                        button.setHovered(hovered)
                        for pressed in [false, true, false] {
                            button.highlight(pressed)
                            let rep = try render()
                            let center = try alpha(rep, 68, 18)
                            let level: CGFloat = pressed ? 0.22 : (selected ? 0.14 : (hovered ? 0.08 : 0))
                            XCTAssertEqual(center, opaque && level > 0 ? 1 : level, accuracy: 0.01)
                            for x in [0, 135] { for y in [0, 35] { XCTAssertEqual(try alpha(rep, x, y), 0, accuracy: 0.01) } }
                            // 包含旧 inset=2 边缘：整条中线必须同色，无内层矩形/边框。
                            for x in 0..<136 { XCTAssertEqual(try alpha(rep, x, 18), center, accuracy: 0.01) }
                            for y in 0..<36 { XCTAssertEqual(try alpha(rep, 68, y), center, accuracy: 0.01) }
                            XCTAssertFalse(button.hasFeedbackAnimation)
                        }
                    }
                }
                button.state = .off
                XCTAssertEqual(try render().representation(using: .png, properties: [:]), baseline.representation(using: .png, properties: [:]))
            }
        }
    }
}
