import AppKit
import AVKit
import XCTest
@testable import 截图Free

@MainActor
final class GlassViewTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    func testAppearanceAccessibilityClippingAndUnmodifiedForeground() throws {
        _ = NSApplication.shared
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let glass = GlassView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
            glass.forceFallback = true
            glass.appearance = NSAppearance(named: name)
            let label = NSTextField(labelWithString: "清晰文字")
            label.textColor = .labelColor
            glass.addSubview(label)
            for reduced in [false, true, false] {
                glass.updateAccessibility(reduceTransparency: reduced)
                XCTAssertEqual(glass.tintOpacity, reduced ? 1 : 0.06)
                XCTAssertEqual(glass.effectView.state, reduced ? .inactive : .active)
                XCTAssertEqual(glass.effectView.material, .hudWindow)
                XCTAssertEqual(glass.effectView.blendingMode, .behindWindow)
                XCTAssertFalse(glass.allowsVibrancy)
                XCTAssertEqual(label.alphaValue, 1)
                XCTAssertEqual(label.textColor, .labelColor)
                XCTAssertTrue(label.superview === glass.controlsHost)
                XCTAssertFalse(glass.effectView.subviews.contains(label))
            }
            glass.setFrameSize(NSSize(width: 460, height: 180))
            glass.layoutSubtreeIfNeeded()
            XCTAssertEqual(glass.effectView.frame, glass.bounds)
            XCTAssertEqual(glass.effectView.subviews.first?.frame, glass.bounds)
            for view in [glass, glass.effectView] {
                XCTAssertEqual(view.layer?.cornerRadius, 14)
                XCTAssertEqual(view.layer?.masksToBounds, true)
                XCTAssertEqual(view.layer?.borderWidth, 0)
                XCTAssertNil(view.layer?.borderColor)
            }
            // 动态系统色保留暗/亮对比，不给文字额外乘透明度。
            glass.effectiveAppearance.performAsCurrentDrawingAppearance {
                let background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)!
                for color in [NSColor.labelColor, .secondaryLabelColor] {
                    let text = color.usingColorSpace(.deviceRGB)!
                    XCTAssertGreaterThan(abs(text.brightnessComponent - background.brightnessComponent), 0.3)
                }
            }
        }
    }

    func testWindowPreparationPreservesBehavior() {
        _ = NSApplication.shared
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let mask = window.styleMask
        let behavior = window.collectionBehavior
        GlassView.prepareWindow(window)
        XCTAssertEqual(window.styleMask, mask)
        XCTAssertEqual(window.collectionBehavior, behavior)
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor.alphaComponent, 0)
        window.close()
    }

    func testControllersInstallGlassWithoutCoveringMedia() throws {
        _ = NSApplication.shared
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let options = RecordingOptionsWindowController(selectionRect: CGRect(x: 100, y: 100, width: 400, height: 300))
        let recording = RecordingControlWindowController(selectionRect: .zero, audioSource: .none, quality: .high)
        let long = LongScreenshotControlWindowController()
        let progress = LongScreenshotProgressOverlayController(selectionRect: CGRect(x: 100, y: 100, width: 400, height: 300))
        let settings = SettingsWindowController(settingsStore: SettingsStore(fileURL: temporaryURL().appendingPathComponent("missing.json")))
        let preview = RecordingPreviewWindowController(url: temporaryURL().appendingPathComponent("missing.mov"))
        settings.show()
        defer {
            options.close()
            recording.close()
            long.close()
            progress.close()
            for window in NSApp.windows where !before.contains(ObjectIdentifier(window)) { window.close() }
            withExtendedLifetime(preview) {}
        }
        let windows = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) }
        let glassWindows = windows.filter { $0.contentView.map { descendants($0).contains { $0 is GlassView } } ?? false }
        XCTAssertEqual(glassWindows.count, 6)
        for window in glassWindows {
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor.alphaComponent, 0)
            for label in descendants(try XCTUnwrap(window.contentView)).compactMap({ $0 as? NSTextField }) where !label.isEditable {
                XCTAssertEqual(label.alphaValue, 1)
                // 无 bezel 的原生 popup 会创建自己的文字子控件，使用系统 controlTextColor。
                XCTAssertTrue(label.textColor == .labelColor || label.textColor == .secondaryLabelColor || label.textColor == .controlTextColor)
            }
        }
        let player = try XCTUnwrap(windows.flatMap { $0.contentView.map(descendants) ?? [] }.compactMap { $0 as? AVPlayerView }.first)
        XCTAssertFalse(player.superview is GlassView)
        XCTAssertFalse(descendants(player).contains { $0 is GlassView })
        let media = try XCTUnwrap(player.superview as? MediaDisplayView)
        let controls = try XCTUnwrap(media.superview?.subviews.compactMap { $0 as? GlassView }.first)
        XCTAssertLessThanOrEqual(controls.frame.maxY, media.frame.minY)
    }
}
