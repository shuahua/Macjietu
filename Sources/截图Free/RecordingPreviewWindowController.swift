import AppKit
import AVKit
import UniformTypeIdentifiers

@MainActor
final class RecordingPreviewWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let sourceURL: URL
    let window: NSWindow
    private let chooseDestination: @MainActor () -> URL?
    private let player: AVPlayer
    private weak var playerView: AVPlayerView?
    private var didCleanup = false
    private var sizeTask: Task<Void, Never>?
    private var presentationObservation: NSKeyValueObservation?
    private let controls = GlassView(frame: .zero)
    private let media = MediaDisplayView(frame: .zero)
    private let loading = NSTextField(labelWithString: "正在读取视频尺寸…")
    private(set) var movieSize: CGSize?
    private var toolbarSize = CGSize(width: 210, height: 52)
    private let visibleFrameOverride: CGRect?

    init(url: URL, chooseDestination: @escaping @MainActor () -> URL? = RecordingPreviewWindowController.chooseSaveDestination,
         visibleFrame: CGRect? = nil,
         sizeLoader: @escaping (URL) async throws -> CGSize? = RecordingMovieGeometry.load) {
        sourceURL = url
        visibleFrameOverride = visibleFrame
        self.chooseDestination = chooseDestination
        player = AVPlayer(url: url)

        window = RecordingPreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 304),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        GlassView.prepareWindow(window)
        window.hasShadow = false
        window.isMovable = true
        window.delegate = self
        window.isReleasedWhenClosed = false

        let contentView = RecordingPreviewRootView(frame: window.contentView?.bounds ?? .zero)
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false
        window.isMovableByWindowBackground = false

        // 仅底部操作栏磨砂；AVPlayerView 及其系统播放控件保持原生。
        controls.castsSoftShadow = true
        controls.dragsWindowOnBackground = true
        controls.toolTip = "拖动此处移动预览；Esc 关闭"
        contentView.addSubview(controls)

        let playerView = AVPlayerView(frame: .zero)
        playerView.autoresizingMask = [.width, .height]
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = false
        playerView.wantsLayer = true
        media.addSubview(playerView)
        media.isHidden = true
        contentView.addSubview(media)
        loading.alignment = .center
        contentView.addSubview(loading)
        self.playerView = playerView

        let saveButton = GlassButton(title: "保存导出", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.sizeToFit()
        controls.addSubview(saveButton)

        let closeButton = GlassButton(title: "关闭", target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.sizeToFit()
        toolbarSize.width = closeButton.frame.width + saveButton.frame.width + 44
        closeButton.setFrameOrigin(NSPoint(x: 16, y: (toolbarSize.height - closeButton.frame.height) / 2))
        saveButton.setFrameOrigin(NSPoint(x: closeButton.frame.maxX + 12, y: (toolbarSize.height - saveButton.frame.height) / 2))
        controls.addSubview(closeButton)

        window.contentView = contentView
        layoutPreview()
        if let item = player.currentItem {
            presentationObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
                let size = item.presentationSize
                Task { @MainActor [weak self] in self?.accept(size) }
            }
        }
        sizeTask = Task { [weak self] in
            let size = try? await sizeLoader(url)
            guard !Task.isCancelled, let self, !self.didCleanup else { return }
            if self.movieSize == nil, let size { self.accept(size) }
            if self.movieSize == nil { self.loading.stringValue = "暂无法读取尺寸，仍可保存导出" }
        }
    }

    private func accept(_ size: CGSize) {
        guard !didCleanup, RecordingMovieGeometry.valid(size) else { return }
        movieSize = size
        media.isHidden = false
        loading.isHidden = true
        layoutPreview()
    }

    private func layoutPreview() {
        let visible = visibleFrameOverride ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let layout = RecordingPreviewLayout(movie: movieSize, toolbarSize: toolbarSize, visible: visible)
        let center = window.isVisible ? NSPoint(x: window.frame.midX, y: window.frame.midY) : NSPoint(x: visible.midX, y: visible.midY)
        window.setContentSize(layout.root)
        controls.frame = layout.toolbar
        media.frame = layout.media
        media.layoutSubtreeIfNeeded()
        loading.frame = CGRect(x: layout.media.minX, y: layout.media.midY - 12, width: layout.media.width, height: 24)
        window.setFrameOrigin(CGPoint(x: max(visible.minX, min(center.x - layout.root.width / 2, visible.maxX - layout.root.width)),
                                      y: max(visible.minY, min(center.y - layout.root.height / 2, visible.maxY - layout.root.height))))
    }

    func show() {
        guard !didCleanup else { return }
        window.makeKeyAndOrderFront(nil)
        GlassMotion.reveal(window.contentView?.subviews.first { $0 is GlassView })
        NSApp.activate(ignoringOtherApps: true)
        player.play()
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
    }

    @objc private func saveClicked() {
        guard !didCleanup else { return }
        player.pause()
        guard let destinationURL = chooseDestination(), !didCleanup else { return }
        guard destinationURL.standardizedFileURL.resolvingSymlinksInPath() != sourceURL.standardizedFileURL.resolvingSymlinksInPath() else { return }

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

    private static func chooseSaveDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存录屏"
        panel.nameFieldStringValue = VideoFileNamer.fileName()
        panel.allowedContentTypes = [.movie]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    @objc private func closeClicked() {
        window.close()
    }

    private func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        sizeTask?.cancel()
        sizeTask = nil
        presentationObservation?.invalidate()
        presentationObservation = nil
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
