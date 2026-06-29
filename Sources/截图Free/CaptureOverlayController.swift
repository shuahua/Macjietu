import AppKit

enum CaptureSelectionResult: Equatable {
    case completed(CGRect)
    case cancelled
}

@MainActor
final class CaptureOverlayController {
    private let completion: (CaptureSelectionResult) -> Void
    private var windows: [CaptureOverlayWindow] = []
    private var didFinish = false

    init(completion: @escaping (CaptureSelectionResult) -> Void) {
        self.completion = completion
    }

    func start() {
        AppLogger.log("CaptureOverlayController start screens=\(NSScreen.screens.count)")
        NSApp.activate(ignoringOtherApps: true)
        let overlayWindows = NSScreen.screens.map { screen in
            CaptureOverlayWindow(screen: screen) { [weak self] result in
                self?.finish(result)
            }
        }
        windows = overlayWindows
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didFinish else { return }
            self.windows.forEach { window in
            window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            window.makeKey()
            if let view = window.contentView {
                window.makeFirstResponder(view)
            }
            }
        }
    }

    func cancel() {
        finish(.cancelled)
    }

    private func finish(_ result: CaptureSelectionResult) {
        guard !didFinish else { return }
        didFinish = true
        AppLogger.log("CaptureOverlayController finish \(result)")
        let windowsToClose = windows
        windowsToClose.forEach { $0.orderOut(nil) }
        windows.removeAll()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [completion] in
            completion(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            windowsToClose.forEach { $0.close() }
        }
    }
}

final class CaptureOverlayWindow: NSWindow {
    init(screen: NSScreen, completion: @escaping (CaptureSelectionResult) -> Void) {
        let view = CaptureOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            screenFrame: screen.frame,
            completion: completion
        )
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        contentView = view
        backgroundColor = .clear
        isOpaque = false
        isReleasedWhenClosed = false
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        initialFirstResponder = view
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CaptureOverlayView: NSView {
    private let completion: (CaptureSelectionResult) -> Void
    private let screenFrame: CGRect
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

    init(frame: CGRect, screenFrame: CGRect, completion: @escaping (CaptureSelectionResult) -> Void) {
        self.completion = completion
        self.screenFrame = screenFrame
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let rect = selectionRect else { return }
        NSColor.clear.setFill()
        rect.fill(using: .clear)
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let rect = selectionRect, rect.width >= 4, rect.height >= 4 else {
            DispatchQueue.main.async { [completion] in completion(.cancelled) }
            return
        }
        let screenRect = CGRect(
            x: screenFrame.minX + rect.minX,
            y: screenFrame.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )
        DispatchQueue.main.async { [completion] in completion(.completed(screenRect)) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            DispatchQueue.main.async { [completion] in completion(.cancelled) }
        }
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        )
    }
}
