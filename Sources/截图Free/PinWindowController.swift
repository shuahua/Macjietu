import AppKit

@MainActor
final class PinWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let image: NSImage
    private var window: NSWindow?

    init(image: NSImage) {
        self.image = image
    }

    func show() {
        let size = scaledSize(image.size)
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let rect = CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        let window = NSWindow(contentRect: rect, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = PinnedImageView(image: image) { [weak self] in
            self?.window?.close()
        }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.window = window
        window.orderFrontRegardless()
        window.makeFirstResponder(window.contentView)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        onClose?()
        onClose = nil
    }

    private func scaledSize(_ imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: 480, height: 320)
        }
        let maxSide: CGFloat = 720
        let scale = min(maxSide / max(imageSize.width, imageSize.height), 1)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

final class PinnedImageView: NSView {
    private let image: NSImage
    private let onClose: () -> Void
    private var closeButton: NSButton?

    init(image: NSImage, onClose: @escaping () -> Void) {
        self.image = image
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        addCloseButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClose()
        } else {
            super.keyDown(with: event)
        }
    }

    private func addCloseButton() {
        let button = NSButton(frame: CGRect(x: bounds.maxX - 34, y: bounds.maxY - 34, width: 26, height: 26))
        button.title = "×"
        button.target = self
        button.action = #selector(closePinnedWindow)
        button.autoresizingMask = [.minXMargin, .minYMargin]
        button.bezelStyle = .circular
        button.font = .systemFont(ofSize: 15, weight: .bold)
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.52).cgColor
        button.layer?.cornerRadius = 13
        closeButton = button
        addSubview(button)
    }

    @objc private func closePinnedWindow() {
        onClose()
    }
}
