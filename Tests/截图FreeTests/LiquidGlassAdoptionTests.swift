import AppKit
import XCTest
@testable import 截图Free

@MainActor
final class LiquidGlassAdoptionTests: XCTestCase {
    final class Receiver: NSObject {
        var count = 0
        @objc func clicked(_ sender: Any?) { count += 1 }
    }

    func testNativeFallbackSwitchKeepsControlIdentityAndHit() throws {
        _ = NSApplication.shared
        let glass = GlassView(frame: NSRect(x: 0, y: 0, width: 240, height: 90))
        let button = GlassButton(title: "操作", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 20, width: 80, height: 30)
        glass.addSubview(button)
        for fallback in [false, true, false] {
            glass.forceFallback = fallback
            for reduced in [false, true, false] {
                glass.updateAccessibility(reduceTransparency: reduced)
                XCTAssertTrue(button.superview === glass.controlsHost)
                XCTAssertEqual(button.alphaValue, 1)
                XCTAssertTrue(glass.hitTest(NSPoint(x: 40, y: 35)) === button)
                if reduced { XCTAssertEqual(glass.backend, .opaque) }
                else if fallback { XCTAssertEqual(glass.backend, .standard) }
                #if compiler(>=6.2) && !LIQUID_GLASS_FALLBACK
                if #available(macOS 26.0, *), !fallback && !reduced {
                    XCTAssertEqual(glass.backend, .native)
                     var candidate: NSView? = glass.controlsHost.superview
                     while candidate != nil && !(candidate is NSGlassEffectView) { candidate = candidate?.superview }
                     let surface = try XCTUnwrap(candidate as? NSGlassEffectView)
                    XCTAssertTrue(surface.contentView === glass.controlsHost)
                    XCTAssertEqual(surface.style, .regular)
                    XCTAssertTrue(glass.effectView.isHidden)
                }
                #endif
            }
        }
    }

    func testFeedbackAnimationActionFocusAndAccessibility() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let receiver = Receiver()
        let button = GlassButton(title: "测试", target: receiver, action: #selector(Receiver.clicked(_:)))
        XCTAssertTrue(type(of: button.cell!) == NSButtonCell.self, "普通按钮必须恢复原生 cell")
        button.frame = NSRect(x: 20, y: 20, width: 80, height: 30)
        window.contentView?.addSubview(button)
        XCTAssertEqual(window.contentView?.subviews.count, 1, "不得插入共享选中装饰")
        XCTAssertFalse(button.layer?.sublayers?.first?.isHidden ?? true, "普通按钮反馈层必须可见")
        button.reduceMotionOverride = false
        let frame = button.frame
        button.setHovered(true)
        XCTAssertEqual(button.feedbackLevel, 0.08)
        XCTAssertTrue(button.hasFeedbackAnimation)
        button.highlight(true)
        XCTAssertEqual(button.feedbackLevel, 0.22)
        button.highlight(false)
        button.setButtonType(.toggle)
        button.state = .on
        XCTAssertEqual(button.feedbackLevel, 0.14)
        _ = button.becomeFirstResponder()
        XCTAssertTrue(button.focused)
        XCTAssertEqual(button.feedbackLevel, 0.18)
        _ = button.resignFirstResponder()
        button.performClick(nil)
        XCTAssertEqual(receiver.count, 1)
        XCTAssertEqual(button.frame, frame)
        button.reduceMotionOverride = true
        button.reduceTransparencyOverride = true
        button.refreshFeedback()
        XCTAssertFalse(button.hasFeedbackAnimation)
        button.isEnabled = false
        XCTAssertEqual(button.feedbackLevel, 0)
        button.performClick(nil)
        XCTAssertEqual(receiver.count, 1)
    }

    func testPanelAnimationDoesNotChangeModelOrWaitForCompletion() {
        let view = GlassView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        GlassMotion.reveal(view, reduceMotion: false)
        XCTAssertNotNil(view.layer?.animation(forKey: "glassReveal"))
        XCTAssertEqual(view.alphaValue, 1)
        GlassMotion.reveal(view, reduceMotion: true)
        XCTAssertNil(view.layer?.animation(forKey: "glassReveal"))
        XCTAssertEqual(view.alphaValue, 1)
    }
}
