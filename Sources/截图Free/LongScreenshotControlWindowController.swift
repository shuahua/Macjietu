import AppKit

@MainActor
final class LongScreenshotControlWindowController: NSWindowController {
    var onCaptureNext: (() -> Void)?
    var onToggleAutoScroll: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let captureButton = NSButton(title: "截取当前段", target: nil, action: nil)
    private let autoScrollButton = NSButton(title: "自动滚动", target: nil, action: nil)
    private let finishButton = NSButton(title: "完成", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var frameCount = 0
    private var isAutoScrolling = false

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 164),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "长截图"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(frameCount: Int, near selectionRect: CGRect? = nil) {
        update(frameCount: frameCount)
        if let selectionRect {
            position(near: selectionRect)
        } else {
            positionNearTopRight()
        }
        window?.orderFrontRegardless()
    }

    var currentFrame: CGRect? {
        window?.frame
    }

    private func position(near selectionRect: CGRect) {
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(selectionRect) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let gap: CGFloat = 12
        let preferRight = selectionRect.midX < visible.midX
        let rightX = selectionRect.maxX + gap
        let leftX = selectionRect.minX - window.frame.width - gap
        let x: CGFloat

        if preferRight {
            x = rightX + window.frame.width <= visible.maxX ? rightX : max(visible.minX + gap, leftX)
        } else {
            x = leftX >= visible.minX ? leftX : min(visible.maxX - window.frame.width - gap, rightX)
        }

        let y = min(max(selectionRect.midY + window.frame.height / 2, visible.minY + window.frame.height + gap), visible.maxY - gap)
        window.setFrameTopLeftPoint(CGPoint(x: x, y: y))
    }

    func update(frameCount: Int) {
        self.frameCount = frameCount
        statusLabel.stringValue = "已截取 \(frameCount) 段"
        hintLabel.stringValue = isAutoScrolling ? "正在自动滚动并截取，可随时停止。" : "可手动滚动，也可点击“自动滚动”。"
        finishButton.isEnabled = frameCount > 0
    }

    func setBusy(_ isBusy: Bool) {
        captureButton.isEnabled = !isBusy && !isAutoScrolling
        autoScrollButton.isEnabled = !isBusy || isAutoScrolling
        finishButton.isEnabled = !isBusy && frameCount > 0
        cancelButton.isEnabled = !isBusy
        if isBusy {
            hintLabel.stringValue = "正在截取当前区域..."
        } else {
            hintLabel.stringValue = isAutoScrolling ? "正在自动滚动并截取，可随时停止。" : "可手动滚动，也可点击“自动滚动”。"
        }
    }

    func setAutoScrolling(_ isAutoScrolling: Bool) {
        self.isAutoScrolling = isAutoScrolling
        autoScrollButton.title = isAutoScrolling ? "停止自动" : "自动滚动"
        captureButton.isEnabled = !isAutoScrolling
        hintLabel.stringValue = isAutoScrolling ? "正在自动滚动并截取，可随时停止。" : "可手动滚动，也可点击“自动滚动”。"
    }

    private func positionNearTopRight() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.maxX - window.frame.width - 24
        let y = visible.maxY - 24
        window.setFrameTopLeftPoint(CGPoint(x: x, y: y))
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor

        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        captureButton.target = self
        captureButton.action = #selector(captureNext)
        captureButton.bezelStyle = .rounded

        autoScrollButton.target = self
        autoScrollButton.action = #selector(toggleAutoScroll)
        autoScrollButton.bezelStyle = .rounded

        finishButton.target = self
        finishButton.action = #selector(finish)
        finishButton.bezelStyle = .rounded
        finishButton.keyEquivalent = "\r"
        finishButton.isEnabled = false

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        buttonStack.addArrangedSubview(captureButton)
        buttonStack.addArrangedSubview(autoScrollButton)
        buttonStack.addArrangedSubview(finishButton)
        buttonStack.addArrangedSubview(cancelButton)

        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(hintLabel)
        stack.addArrangedSubview(buttonStack)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    @objc private func captureNext() {
        onCaptureNext?()
    }

    @objc private func toggleAutoScroll() {
        onToggleAutoScroll?()
    }

    @objc private func finish() {
        setBusy(true)
        hintLabel.stringValue = "正在拼接..."
        onFinish?()
    }

    @objc private func cancel() {
        onCancel?()
    }
}
