import AppKit

@MainActor
final class RecordingControlWindowController: NSObject {
    var onStop: (() -> Void)?

    private let window: NSWindow
    private let elapsedLabel = NSTextField(labelWithString: "00:00")
    private let recordingDot = RecordingDotView(frame: NSRect(x: 14, y: 23, width: 12, height: 12))
    private let windowSize = CGSize(width: 390, height: 64)
    private var startedAt = Date()
    private var timer: Timer?

    init(selectionRect: CGRect, audioSource: RecordingAudioSource, quality: RecordingQuality) {
        let contentView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.contentView = contentView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let panel = RoundedPanelView(frame: contentView.bounds)
        contentView.addSubview(panel)

        contentView.addSubview(recordingDot)

        let title = NSTextField(labelWithString: "正在录制")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .labelColor
        title.frame = NSRect(x: 34, y: 31, width: 80, height: 18)
        contentView.addSubview(title)

        let sourceLabel = NSTextField(labelWithString: "\(audioSource.title) · \(quality.title)")
        sourceLabel.font = .systemFont(ofSize: 11, weight: .regular)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.frame = NSRect(x: 96, y: 31, width: 190, height: 18)
        contentView.addSubview(sourceLabel)

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        elapsedLabel.textColor = .labelColor
        elapsedLabel.frame = NSRect(x: 34, y: 11, width: 76, height: 20)
        contentView.addSubview(elapsedLabel)

        let stopButton = NSButton(title: "完成", target: self, action: #selector(stopClicked))
        stopButton.bezelStyle = .rounded
        stopButton.frame = NSRect(x: 308, y: 17, width: 68, height: 30)
        contentView.addSubview(stopButton)

        let screen = NSScreen.screens.first { $0.frame.intersects(selectionRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(selectionRect.midX - windowSize.width / 2, visible.minX + 12), visible.maxX - windowSize.width - 12)
        let y = selectionRect.minY - 80 >= visible.minY + 12 ? selectionRect.minY - 80 : min(selectionRect.maxY + 12, visible.maxY - 64 - 12)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() {
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
        window.orderFrontRegardless()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        onStop = nil
        window.contentView = nil
        window.close()
    }

    @objc private func stopClicked() {
        onStop?()
    }

    private func updateElapsed() {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        elapsedLabel.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        recordingDot.isHighlighted = elapsed % 2 == 0
        recordingDot.needsDisplay = true
    }
}

private final class RecordingDotView: NSView {
    var isHighlighted = true

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = NSColor.systemRed.withAlphaComponent(isHighlighted ? 1 : 0.45)
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}
