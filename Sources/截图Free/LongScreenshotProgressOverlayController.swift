import AppKit

@MainActor
final class LongScreenshotProgressOverlayController {
    var onDoubleClickSelection: (() -> Void)?
    var onAutomaticToggle: (() -> Void)?

    private let borderWindow: NSWindow
    private let thumbnailWindow: NSWindow
    private let thumbnailView = LongScreenshotThumbnailView(frame: CGRect(x: 0, y: 0, width: 248, height: 180))
    private let selectionRect: CGRect
    private var avoidedFrame: CGRect?
    private var isThumbnailVisible = false
    private var doubleClickMonitor: Any?
    private var isCaptureHidden = false
    private var isClosed = false
    private(set) var previewImage: NSImage?
    private let automaticButton = GlassButton(title: "自动滚动", target: nil, action: nil)
    private let finishButton = GlassButton(title: "完成长截图", target: nil, action: nil)
    var captureWindowIDs: Set<CGWindowID> {
        Set([borderWindow, thumbnailWindow].filter { $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
    }

    func setStatus(_ text: String?) {
        thumbnailView.statusText = text
        thumbnailView.needsDisplay = true
    }

    func setAutomaticScrollState(isRunning: Bool, available: Bool) {
        automaticButton.title = isRunning ? "暂停自动" : "自动滚动"
        automaticButton.isEnabled = isRunning || available
        automaticButton.toolTip = available ? "切换自动滚动；暂停后可手动调整" : "自动滚动需要辅助功能权限"
        thumbnailView.automaticScrollRunning = isRunning
        thumbnailView.automaticScrollAvailable = available
        thumbnailView.needsDisplay = true
    }

    @objc private func automaticClicked() { onAutomaticToggle?() }
    @objc private func finishClicked() { onDoubleClickSelection?() }

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
            contentRect: CGRect(x: 0, y: 0, width: 248, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let glass = GlassView(frame: CGRect(x: 0, y: 0, width: thumbnailView.bounds.width, height: 32))
        glass.autoresizingMask = [.width, .maxYMargin]
        thumbnailView.autoresizingMask = [.width, .height]
        thumbnailWindow.contentView = thumbnailView
        thumbnailView.addSubview(glass)
        thumbnailWindow.backgroundColor = .clear
        thumbnailWindow.isOpaque = false
        thumbnailWindow.ignoresMouseEvents = false
        thumbnailWindow.level = .statusBar
        thumbnailWindow.isReleasedWhenClosed = false
        thumbnailWindow.hasShadow = true
        thumbnailWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        automaticButton.target = self
        automaticButton.action = #selector(automaticClicked)
        automaticButton.frame = CGRect(x: 8, y: 4, width: 108, height: 24)
        glass.addSubview(automaticButton)
        finishButton.target = self
        finishButton.action = #selector(finishClicked)
        finishButton.frame = CGRect(x: 128, y: 4, width: 112, height: 24)
        glass.addSubview(finishButton)

        borderView.onDoubleClick = { [weak self] in self?.onDoubleClickSelection?() }
    }

    func show() {
        guard !isClosed else { return }
        thumbnailView.update(image: nil, frameCount: 0)
        positionThumbnail(size: thumbnailWindow.frame.size)
        startDoubleClickMonitor()
        restoreVisibleWindows()
    }

    func updatePreview(image: NSImage, frameCount: Int) {
        guard !isClosed else { return }
        let size = thumbnailSize(for: image)
        previewImage = image
        thumbnailWindow.setContentSize(size)
        thumbnailView.frame = CGRect(origin: .zero, size: size)
        thumbnailView.update(image: image, frameCount: frameCount)
        positionThumbnail(size: size)
        restoreVisibleWindows()
        AppLogger.log("manual long screenshot preview updated frames=\(frameCount) size=\(image.size) window=\(thumbnailWindow.frame)")
    }

    func setSelectionBorderHidden(_ isHidden: Bool) {
        guard !isClosed else { return }
        // 保留协调器调用接口，但必须连缩略图及阴影一起隐藏。
        isCaptureHidden = isHidden
        if isHidden {
            borderWindow.orderOut(nil)
            thumbnailWindow.orderOut(nil)
        } else {
            restoreVisibleWindows()
        }
    }

    private func restoreVisibleWindows() {
        guard !isClosed, !isCaptureHidden else { return }
        if !borderWindow.isVisible { borderWindow.orderFrontRegardless() }
        if isThumbnailVisible && !thumbnailWindow.isVisible { thumbnailWindow.orderFrontRegardless() }
    }

    func avoid(frame: CGRect) {
        avoidedFrame = frame
        positionThumbnail(size: thumbnailWindow.frame.size)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        onDoubleClickSelection = nil
        onAutomaticToggle = nil
        stopDoubleClickMonitor()
        borderWindow.orderOut(nil)
        thumbnailWindow.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [borderWindow, thumbnailWindow] in
            borderWindow.close()
            thumbnailWindow.close()
        }
    }

    private func thumbnailSize(for image: NSImage) -> CGSize {
        let width: CGFloat = 248
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
            Task { @MainActor in
                guard !self.isClosed else { return }
                self.onDoubleClickSelection?()
            }
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
    var statusText: String?
    var automaticScrollRunning = false
    var automaticScrollAvailable = false
    private var image: NSImage?
    private var frameCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
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

        let defaultText: String
        if frameCount == 0 {
            defaultText = "正在捕获首帧…"
        } else if automaticScrollRunning {
            defaultText = "自动滚动中 · 已拼接 \(frameCount) 段"
        } else if automaticScrollAvailable {
            defaultText = "已拼接 \(frameCount) 段 · 可自动或手动滚动"
        } else {
            defaultText = "已拼接 \(frameCount) 段 · 手动慢滚更稳"
        }
        let text = statusText ?? defaultText
        let labelHeight: CGFloat = 68
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

        let textRect = CGRect(x: 10, y: 32, width: bounds.width - 20, height: labelHeight - 24)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
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
