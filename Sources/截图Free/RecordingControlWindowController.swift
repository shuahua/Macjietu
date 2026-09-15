import AppKit

@MainActor
final class RecordingControlWindowController: NSObject {
    var onStop: (() -> Void)?

    let window: NSWindow
    private let elapsedLabel = NSTextField(labelWithString: "00:00")
    private let recordingDot = RecordingDotView(frame: NSRect(x: 14, y: 23, width: 12, height: 12))
    private let windowSize = CGSize(width: 390, height: 64)
    private var startedAt = Date()
    private var timer: Timer?
    private var didStop = false
    private let stopButton = GlassButton()

    init(selectionRect: CGRect, audioSource: RecordingAudioSource, quality: RecordingQuality, visibleFrame: CGRect? = nil) {
        let contentView = GlassView(frame: NSRect(origin: .zero, size: windowSize))
        window = RecordingToolbarPanel(glass: contentView, title: "录屏控制")
        super.init()

        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

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

        stopButton.title = "完成"
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.bezelStyle = .rounded
        stopButton.frame = NSRect(x: 308, y: 17, width: 68, height: 30)
        contentView.addSubview(stopButton)

        title.sizeToFit()
        sourceLabel.sizeToFit()
        sourceLabel.toolTip = sourceLabel.stringValue
        RecordingLayout.row([recordingDot, title, elapsedLabel, sourceLabel, stopButton], in: contentView,
                            window: window, selection: selectionRect,
                            visible: visibleFrame ?? RecordingLayout.visibleFrame(for: selectionRect))
    }

    func show() {
        guard !didStop, window.contentView != nil else { return }
        timer?.invalidate()
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
        window.orderFrontRegardless()
        GlassMotion.reveal(window.contentView)
    }

    func close() {
        didStop = true
        stopButton.isEnabled = false
        timer?.invalidate()
        timer = nil
        onStop = nil
        window.contentView = nil
        window.close()
    }

    @objc private func stopClicked() {
        guard !didStop else { return }
        didStop = true
        stopButton.isEnabled = false
        timer?.invalidate()
        timer = nil
        let callback = onStop
        onStop = nil
        callback?()
    }

    private func updateElapsed() {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        elapsedLabel.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        recordingDot.isHighlighted = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || elapsed % 2 == 0
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
