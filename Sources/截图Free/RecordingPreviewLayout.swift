import AppKit
import AVFoundation

enum RecordingMovieGeometry {
    static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    static func displaySize(_ size: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    static func load(_ url: URL) async throws -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let formats = try await track.load(.formatDescriptions)
        // clean aperture 与像素宽高比先作用于编码平面，再应用影片旋转。
        let presentation = formats.first.map {
            CMVideoFormatDescriptionGetPresentationDimensions($0, usePixelAspectRatio: true, useCleanAperture: true)
        }
        let size = displaySize(presentation.flatMap { valid($0) ? $0 : nil } ?? natural, transform: transform)
        return valid(size) ? size : nil
    }
}

@MainActor
final class RecordingPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// 透明留白不参与 AppKit 命中；WindowServer 依赖真正透明的根 backing。
final class RecordingPreviewRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor
struct RecordingPreviewLayout {
    let root: CGSize
    let media: CGRect
    let toolbar: CGRect

    init(movie: CGSize?, toolbarSize: CGSize, visible: CGRect) {
        let padding = GlassView.shadowPadding
        let gap: CGFloat = 20
        let available = CGSize(width: max(1, visible.width - 32 - padding * 2),
                               height: max(1, visible.height - 32 - padding * 2 - toolbarSize.height - gap))
        let source = movie.flatMap { RecordingMovieGeometry.valid($0) ? $0 : nil } ?? CGSize(width: 320, height: 180)
        let scale = min(1, available.width / source.width, available.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        root = CGSize(width: max(size.width, toolbarSize.width) + padding * 2,
                      height: size.height + toolbarSize.height + gap + padding * 2)
        toolbar = CGRect(x: (root.width - toolbarSize.width) / 2, y: padding, width: toolbarSize.width, height: toolbarSize.height)
        media = CGRect(x: (root.width - size.width) / 2, y: toolbar.maxY + gap, width: size.width, height: size.height)
    }
}
