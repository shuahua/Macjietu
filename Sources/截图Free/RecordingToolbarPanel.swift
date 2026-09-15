import AppKit

/// 浮动录屏控件可取得键盘焦点，但不成为主窗口或依靠背景拖动截获鼠标。
@MainActor
final class RecordingToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(glass: GlassView, title: String) {
        let padding = GlassView.shadowPadding
        let size = NSSize(width: glass.frame.width + padding * 2, height: glass.frame.height + padding * 2)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        GlassView.prepareWindow(self)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.masksToBounds = false
        glass.setFrameOrigin(NSPoint(x: padding, y: padding))
        glass.castsSoftShadow = true
        root.addSubview(glass)
        contentView = root
    }
}
