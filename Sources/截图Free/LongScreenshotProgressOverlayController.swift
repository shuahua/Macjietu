import AppKit

@MainActor
final class LongScreenshotProgressOverlayController {
    var onDoubleClickSelection: (() -> Void)?

    private let borderWindow: NSWindow
    private let thumbnailWindow: NSWindow
    private let thumbnailView = LongScreenshotThumbnailView(frame: CGRect(x: 0, y: 0, width: 220, height: 180))
    private let selectionRect: CGRect
    private var avoidedFrame: CGRect?
    private var isThumbnailVisible = false
    private var doubleClickMonitor: Any?

    init(selectionRect: CGRect) {
        self.selectionRect = selectionRect
        let borderInset: CGFloat = 10
        let borderFrame = selectionRect.insetBy(dx: -borderInset, dy: -borderInset)

        borderWindow = NSWindow(
            contentRect: borderFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let borderView = LongScreenshotSelectionBorderView(frame: CGRect(origin: .zero, size: borderFrame.size), borderInset: borderInset)
        borderWindow.contentView = borderView
        borderWindow.backgroundColor = .clear
        borderWindow.isOpaque = false
        borderWindow.ignoresMouseEvents = true
        borderWindow.level = .floating
        borderWindow.isReleasedWhenClosed = false
        borderWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        thumbnailWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 220, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        thumbnailWindow.contentView = thumbnailView
        thumbnailWindow.backgroundColor = .clear
        thumbnailWindow.isOpaque = false
        thumbnailWindow.ignoresMouseEvents = true
        thumbnailWindow.level = .statusBar
        thumbnailWindow.isReleasedWhenClosed = false
        thumbnailWindow.hasShadow = true
        thumbnailWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        borderView.onDoubleClick = { [weak self] in self?.onDoubleClickSelection?() }
    }

    func show() {
        thumbnailView.update(image: nil, frameCount: 0)
        positionThumbnail(size: thumbnailWindow.frame.size)
        startDoubleClickMonitor()
        borderWindow.orderFrontRegardless()
        if isThumbnailVisible {
            thumbnailWindow.orderFrontRegardless()
        }
    }

    func updatePreview(image: NSImage, frameCount: Int) {
        let size = thumbnailSize(for: image)
        thumbnailWindow.setContentSize(size)
        thumbnailView.frame = CGRect(origin: .zero, size: size)
        thumbnailView.update(image: image, frameCount: frameCount)
        positionThumbnail(size: size)
        if isThumbnailVisible {
            thumbnailWindow.orderFrontRegardless()
        }
        AppLogger.log("manual long screenshot preview updated frames=\(frameCount) size=\(image.size) window=\(thumbnailWindow.frame)")
    }

    func setSelectionBorderHidden(_ isHidden: Bool) {
        if isHidden {
            borderWindow.orderOut(nil)
        } else {
            borderWindow.orderFrontRegardless()
        }
    }

    func avoid(frame: CGRect) {
        avoidedFrame = frame
        positionThumbnail(size: thumbnailWindow.frame.size)
    }

    func close() {
        stopDoubleClickMonitor()
        borderWindow.orderOut(nil)
        thumbnailWindow.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [borderWindow, thumbnailWindow] in
            borderWindow.close()
            thumbnailWindow.close()
        }
    }

    private func thumbnailSize(for image: NSImage) -> CGSize {
        let width: CGFloat = 220
        let imageWidth = max(image.size.width, 1)
        let imageHeight = max(image.size.height, 1)
        let height = min(max(width * imageHeight / imageWidth, 140), 420)
        return CGSize(width: width, height: height)
    }

    private func positionThumbnail(size: CGSize) {
        let screen = NSScreen.screens.first { $0.frame.intersects(selectionRect) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let gap: CGFloat = 12
        let preferRight = selectionRect.midX < visible.midX
        let rightX = selectionRect.maxX + gap
        let leftX = selectionRect.minX - size.width - gap
        let canFitRight = rightX + size.width <= visible.maxX - gap
        let canFitLeft = leftX >= visible.minX + gap
        let x: CGFloat

        if preferRight, canFitRight {
            x = rightX
        } else if !preferRight, canFitLeft {
            x = leftX
        } else if canFitRight {
            x = rightX
        } else if canFitLeft {
            x = leftX
        } else {
            isThumbnailVisible = false
            thumbnailWindow.orderOut(nil)
            AppLogger.log("manual long screenshot preview hidden; no outside space selection=\(selectionRect) size=\(size) visible=\(visible)")
            return
        }

        isThumbnailVisible = true

        var y = min(max(selectionRect.maxY - size.height, visible.minY + gap), visible.maxY - size.height - gap)
        if let avoidedFrame {
            let candidate = CGRect(origin: CGPoint(x: x, y: y), size: size)
            if candidate.insetBy(dx: -gap, dy: -gap).intersects(avoidedFrame) {
                let belowY = avoidedFrame.minY - size.height - gap
                let aboveY = avoidedFrame.maxY + gap
                if belowY >= visible.minY + gap {
                    y = belowY
                } else if aboveY + size.height <= visible.maxY - gap {
                    y = aboveY
                }
            }
        }
        thumbnailWindow.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
    }

    private func startDoubleClickMonitor() {
        stopDoubleClickMonitor()
        doubleClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.clickCount >= 2, self.isNearSelectionBorder(event.locationInWindow) else { return }
            Task { @MainActor in self.onDoubleClickSelection?() }
        }
    }

    private func stopDoubleClickMonitor() {
        if let doubleClickMonitor {
            NSEvent.removeMonitor(doubleClickMonitor)
            self.doubleClickMonitor = nil
        }
    }

    private func isNearSelectionBorder(_ point: CGPoint) -> Bool {
        selectionRect.contains(point)
    }
}

private final class LongScreenshotSelectionBorderView: NSView {
    var onDoubleClick: (() -> Void)?

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

        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: borderInset / 2, dy: borderInset / 2), xRadius: 6, yRadius: 6)
        border.lineWidth = 3
        border.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let outer = bounds
        let inner = bounds.insetBy(dx: borderInset + 6, dy: borderInset + 6)
        return outer.contains(point) && !inner.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
        }
    }
}

private final class LongScreenshotThumbnailView: NSView {
    private var image: NSImage?
    private var frameCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.8).cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(image: NSImage?, frameCount: Int) {
        self.image = image
        self.frameCount = frameCount
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let panelRect = bounds.insetBy(dx: 1, dy: 1)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: panelRect, xRadius: 14, yRadius: 14).fill()

        let text = frameCount == 0 ? "等待截取第一段\n按 Esc 完成截图" : "已截取 \(frameCount) 段\n按 Esc 完成截图"
        let labelHeight: CGFloat = 38
        let imageRect = CGRect(
            x: 10,
            y: 10 + labelHeight,
            width: bounds.width - 20,
            height: max(1, bounds.height - 20 - labelHeight - 8)
        )

        if let image {
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: imageRect, xRadius: 10, yRadius: 10).fill()
            draw(image: image, in: imageRect.insetBy(dx: 4, dy: 4))
        } else {
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: imageRect, xRadius: 10, yRadius: 10).fill()
        }

        let textRect = CGRect(x: 10, y: 8, width: bounds.width - 20, height: labelHeight)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]
        text.draw(in: textRect, withAttributes: attributes)
    }

    private func draw(image: NSImage, in rect: CGRect) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
