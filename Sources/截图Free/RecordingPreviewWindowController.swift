import AppKit
import AVKit
import UniformTypeIdentifiers

@MainActor
final class RecordingPreviewWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let sourceURL: URL
    private let window: NSWindow
    private let player: AVPlayer
    private weak var playerView: AVPlayerView?
    private var didCleanup = false

    init(url: URL) {
        sourceURL = url
        player = AVPlayer(url: url)

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(960, screenFrame.width - 80)
        let height = min(680, screenFrame.height - 80)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "录屏预览"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        contentView.autoresizingMask = [.width, .height]

        let playerView = AVPlayerView(frame: NSRect(x: 0, y: 56, width: width, height: height - 56))
        playerView.autoresizingMask = [.width, .height]
        playerView.player = player
        playerView.controlsStyle = .floating
        contentView.addSubview(playerView)
        self.playerView = playerView

        let saveButton = NSButton(title: "保存导出", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.frame = NSRect(x: width - 112, y: 14, width: 92, height: 30)
        saveButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(saveButton)

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: width - 190, y: 14, width: 66, height: 30)
        closeButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(closeButton)

        window.contentView = contentView
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        player.play()
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
    }

    @objc private func saveClicked() {
        player.pause()
        let panel = NSSavePanel()
        panel.title = "保存录屏"
        panel.nameFieldStringValue = VideoFileNamer.fileName()
        panel.allowedContentTypes = [.movie]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            window.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "保存录屏失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func closeClicked() {
        window.close()
    }

    private func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        player.pause()
        player.replaceCurrentItem(with: nil)
        playerView?.player = nil
        playerView?.removeFromSuperview()
        playerView = nil
        window.contentView = nil
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        onClose?()
        onClose = nil
    }
}
