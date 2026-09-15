import AppKit

/// 统一使用屏幕坐标，包含左侧/下方显示器的负坐标。
@MainActor
enum RecordingLayout {
    static func visibleFrame(for selection: CGRect) -> CGRect {
        let screen = NSScreen.screens.max { a, b in
            let x = a.frame.intersection(selection), y = b.frame.intersection(selection)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        }
        return screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
    }

    static func origin(selection: CGRect, size: CGSize, visible: CGRect) -> CGPoint {
        let x = max(visible.minX, min(selection.midX - size.width / 2, visible.maxX - size.width))
        let below = selection.minY - size.height - 12
        let y = below >= visible.minY ? below : selection.maxY + 12
        return CGPoint(x: x, y: max(visible.minY, min(y, visible.maxY - size.height)))
    }

    /// 常规屏幕按自然尺寸；极窄可用区整体等比收缩，仍保留全部菜单和按钮。
    static func row(_ views: [NSView], in glass: GlassView, window: NSWindow, selection: CGRect,
                    visible: CGRect, spacing: CGFloat = 10) {
        let width = views.reduce(CGFloat(24)) { $0 + $1.frame.width } + CGFloat(max(0, views.count - 1)) * spacing
        let height: CGFloat = 48
        let padding = GlassView.shadowPadding
        let scale = min(1, max(1, visible.width - padding * 2 - 16) / width,
                        max(1, visible.height - padding * 2 - 16) / height)
        let row = NSView(frame: CGRect(x: 0, y: 0, width: width * scale, height: height * scale))
        row.setBoundsSize(CGSize(width: width, height: height))
        var x: CGFloat = 12
        for view in views {
            view.setFrameOrigin(CGPoint(x: x, y: (height - view.frame.height) / 2))
            row.addSubview(view)
            x += view.frame.width + spacing
        }
        glass.setFrameSize(row.frame.size)
        glass.addSubview(row)
        window.setContentSize(CGSize(width: glass.frame.width + padding * 2, height: glass.frame.height + padding * 2))
        if let root = window.contentView {
            glass.setFrameOrigin(CGPoint(x: (root.bounds.width - glass.frame.width) / 2,
                                         y: (root.bounds.height - glass.frame.height) / 2))
        }
        window.setFrameOrigin(origin(selection: selection, size: window.frame.size, visible: visible))
    }
}
