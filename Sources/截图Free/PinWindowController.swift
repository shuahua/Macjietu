import AppKit

@MainActor
final class PinWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    private(set) var image: NSImage?
    private(set) var window: NSWindow?
    private var isClosed = false

    init(image: NSImage) {
        self.image = image
    }

    func show() {
        guard !isClosed, window == nil, let image else { return }
        let screenFrame = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let rect = Self.initialFrame(imageSize: image.size, visibleFrame: screenFrame)

        let window = PinWindow(contentRect: rect, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = PinnedImageView(image: image) { [weak self] in
            self?.close()
        }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = CGSize(width: 1, height: 1)
        window.delegate = self
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.window = window
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(window.contentView)
    }

    func close() {
        guard !isClosed else { return }
        let closingWindow = window
        cleanup()
        closingWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        cleanup()
    }

    private func cleanup() {
        guard !isClosed else { return }
        isClosed = true
        (window?.contentView as? PinnedImageView)?.releaseResources()
        window?.delegate = nil
        window?.contentView = nil
        window = nil
        image = nil
        let callback = onClose
        onClose = nil
        callback?()
    }

    static func initialFrame(imageSize: CGSize, visibleFrame: CGRect) -> CGRect {
        let source = imageSize.width > 0 && imageSize.height > 0 ? imageSize : CGSize(width: 480, height: 320)
        let scale = min(1, 720 / max(source.width, source.height),
                        max(1, visibleFrame.width) / source.width,
                        max(1, visibleFrame.height) / source.height)
        let size = CGSize(width: min(visibleFrame.width, source.width * scale),
                          height: min(visibleFrame.height, source.height * scale))
        return CGRect(x: floor(visibleFrame.midX - size.width / 2), y: floor(visibleFrame.midY - size.height / 2),
                      width: size.width, height: size.height)
    }
}

private final class PinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { close() }
}

final class PinnedImageView: NSView {
    private(set) var image: NSImage?
    private var onClose: (() -> Void)?

    init(image: NSImage, onClose: @escaping () -> Void) {
        self.image = image
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    var imageRect: CGRect {
        bounds
    }

    func releaseResources() {
        image = nil
        onClose = nil
        menu = nil
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "关闭贴图", action: #selector(closePinnedWindow), keyEquivalent: "")
        menu.items[0].target = self
        return menu
    }

    @objc private func closePinnedWindow() {
        onClose?()
    }
}
