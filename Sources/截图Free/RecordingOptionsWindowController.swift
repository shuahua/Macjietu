import AppKit

@MainActor
final class RecordingOptionsWindowController: NSObject {
    var onStart: ((RecordingAudioSource, RecordingQuality) -> Void)?
    var onCancel: (() -> Void)?

    private let window: NSWindow
    private let audioPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(selectionRect: CGRect) {
        let size = CGSize(width: 476, height: 70)
        let contentView = NSView(frame: CGRect(origin: .zero, size: size))
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

        let title = NSTextField(labelWithString: "录屏设置")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.frame = CGRect(x: 16, y: 41, width: 74, height: 18)
        contentView.addSubview(title)

        addLabel("音频", x: 104, y: 43, to: contentView)
        audioPopup.frame = CGRect(x: 138, y: 38, width: 132, height: 26)
        RecordingAudioSource.allCases.forEach { audioPopup.addItem(withTitle: $0.title) }
        audioPopup.selectItem(withTitle: RecordingAudioSource.none.title)
        contentView.addSubview(audioPopup)

        addLabel("清晰度", x: 282, y: 43, to: contentView)
        qualityPopup.frame = CGRect(x: 328, y: 38, width: 74, height: 26)
        RecordingQuality.allCases.forEach { qualityPopup.addItem(withTitle: $0.title) }
        qualityPopup.selectItem(withTitle: RecordingQuality.high.title)
        contentView.addSubview(qualityPopup)

        let startButton = NSButton(title: "开始", target: self, action: #selector(startClicked))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.frame = CGRect(x: 314, y: 10, width: 70, height: 28)
        contentView.addSubview(startButton)

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = CGRect(x: 392, y: 10, width: 68, height: 28)
        contentView.addSubview(cancelButton)

        let hint = NSTextField(labelWithString: "确认录制范围后开始")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = CGRect(x: 16, y: 13, width: 180, height: 16)
        contentView.addSubview(hint)

        window.setFrameOrigin(Self.origin(for: selectionRect, size: size))
    }

    func show() {
        window.orderFrontRegardless()
    }

    func close() {
        onStart = nil
        onCancel = nil
        window.contentView = nil
        window.close()
    }

    @objc private func startClicked() {
        let audio = RecordingAudioSource.allCases[max(0, audioPopup.indexOfSelectedItem)]
        let quality = RecordingQuality.allCases[max(0, qualityPopup.indexOfSelectedItem)]
        onStart?(audio, quality)
    }

    @objc private func cancelClicked() {
        onCancel?()
    }

    private func addLabel(_ text: String, x: CGFloat, y: CGFloat, to view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = CGRect(x: x, y: y, width: 44, height: 16)
        view.addSubview(label)
    }

    private static func origin(for selectionRect: CGRect, size: CGSize) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(selectionRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(selectionRect.midX - size.width / 2, visible.minX + 12), visible.maxX - size.width - 12)
        let belowY = selectionRect.minY - size.height - 12
        let y = belowY >= visible.minY + 12 ? belowY : min(selectionRect.maxY + 12, visible.maxY - size.height - 12)
        return CGPoint(x: x, y: y)
    }
}

final class RoundedPanelView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
        NSColor.separatorColor.withAlphaComponent(0.75).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        border.lineWidth = 1
        border.stroke()
    }
}
