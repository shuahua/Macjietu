import AppKit

@MainActor
final class RecordingOptionsWindowController: NSObject {
    var onStart: ((RecordingAudioSource, RecordingQuality) -> Void)?
    var onCancel: (() -> Void)?

    let window: NSWindow
    private let audioPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var didResolve = false

    init(selectionRect: CGRect, visibleFrame: CGRect? = nil) {
        let size = CGSize(width: 476, height: 70)
        let contentView = GlassView(frame: CGRect(origin: .zero, size: size))
        window = RecordingToolbarPanel(glass: contentView, title: "录屏设置")
        super.init()

        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "录屏设置")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.frame = CGRect(x: 16, y: 41, width: 74, height: 18)
        contentView.addSubview(title)

        let audioLabel = addLabel("音频", x: 104, y: 43, to: contentView)
        audioLabel.setFrameSize(CGSize(width: 28, height: 16))
        audioPopup.frame = CGRect(x: 138, y: 38, width: 132, height: 26)
        RecordingAudioSource.allCases.forEach { audioPopup.addItem(withTitle: $0.title) }
        audioPopup.selectItem(withTitle: RecordingAudioSource.none.title)
        contentView.addSubview(audioPopup)

        let qualityLabel = addLabel("清晰度", x: 282, y: 43, to: contentView)
        qualityLabel.setFrameSize(CGSize(width: 38, height: 16))
        qualityPopup.frame = CGRect(x: 328, y: 38, width: 74, height: 26)
        RecordingQuality.allCases.forEach { qualityPopup.addItem(withTitle: $0.title) }
        qualityPopup.selectItem(withTitle: RecordingQuality.high.title)
        contentView.addSubview(qualityPopup)

        let startButton = GlassButton(title: "开始", target: self, action: #selector(startClicked))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.frame = CGRect(x: 314, y: 10, width: 70, height: 28)
        contentView.addSubview(startButton)

        let cancelButton = GlassButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = CGRect(x: 392, y: 10, width: 68, height: 28)
        contentView.addSubview(cancelButton)

        startButton.toolTip = "确认录制范围后开始"
        RecordingLayout.row([title, audioLabel, audioPopup, qualityLabel, qualityPopup, startButton, cancelButton],
                            in: contentView, window: window, selection: selectionRect,
                            visible: visibleFrame ?? RecordingLayout.visibleFrame(for: selectionRect))
    }

    func show() {
        guard !didResolve else { return }
        window.makeKeyAndOrderFront(nil)
        GlassMotion.reveal(window.contentView)
    }

    func close() {
        resolve()
        onStart = nil
        onCancel = nil
        window.contentView = nil
        window.close()
    }

    @objc private func startClicked() {
        guard !didResolve else { return }
        let audio = RecordingAudioSource.allCases[max(0, audioPopup.indexOfSelectedItem)]
        let quality = RecordingQuality.allCases[max(0, qualityPopup.indexOfSelectedItem)]
        let callback = onStart
        resolve()
        callback?(audio, quality)
    }

    @objc private func cancelClicked() {
        guard !didResolve else { return }
        let callback = onCancel
        resolve()
        callback?()
    }

    private func resolve() {
        didResolve = true
        onStart = nil
        onCancel = nil
        func disable(_ view: NSView) {
            (view as? NSControl)?.isEnabled = false
            view.subviews.forEach(disable)
        }
        if let root = window.contentView { disable(root) }
    }

    private func addLabel(_ text: String, x: CGFloat, y: CGFloat, to view: NSView) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = CGRect(x: x, y: y, width: 44, height: 16)
        view.addSubview(label)
        return label
    }
}
