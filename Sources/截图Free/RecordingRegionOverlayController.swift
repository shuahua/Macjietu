import AppKit

@MainActor
final class RecordingRegionOverlayController {
    private let window: NSWindow

    init(selectionRect: CGRect) {
        let borderInset: CGFloat = 8
        let windowFrame = selectionRect.insetBy(dx: -borderInset, dy: -borderInset)
        let view = RecordingRegionOverlayView(frame: CGRect(origin: .zero, size: windowFrame.size), borderInset: borderInset)

        window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show() {
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [window] in
            window.contentView = nil
            window.close()
        }
    }
}

private final class RecordingRegionOverlayView: NSView {
    private let borderInset: CGFloat

    init(frame frameRect: NSRect, borderInset: CGFloat) {
        self.borderInset = borderInset
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        bounds.fill()

        let rect = bounds.insetBy(dx: borderInset / 2, dy: borderInset / 2)
        NSColor.systemRed.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        border.lineWidth = 3
        border.stroke()

        let glow = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 9, yRadius: 9)
        NSColor.systemRed.withAlphaComponent(0.25).setStroke()
        glow.lineWidth = 6
        glow.stroke()

        drawCornerHandles(in: rect)
    }

    private func drawCornerHandles(in rect: CGRect) {
        NSColor.systemRed.setFill()
        let size = CGSize(width: 12, height: 12)
        let points = [
            CGPoint(x: rect.minX - size.width / 2, y: rect.minY - size.height / 2),
            CGPoint(x: rect.maxX - size.width / 2, y: rect.minY - size.height / 2),
            CGPoint(x: rect.minX - size.width / 2, y: rect.maxY - size.height / 2),
            CGPoint(x: rect.maxX - size.width / 2, y: rect.maxY - size.height / 2)
        ]
        points.forEach { origin in
            NSBezierPath(ovalIn: CGRect(origin: origin, size: size)).fill()
        }
    }
}
