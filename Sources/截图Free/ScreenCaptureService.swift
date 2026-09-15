import AppKit
import CoreGraphics

enum ScreenCaptureError: LocalizedError {
    case failed
    case imageEncodingFailed
    case screenRecordingPermissionRequired

    var errorDescription: String? {
        switch self {
        case .failed: return "无法捕获选中区域。"
        case .imageEncodingFailed: return "无法编码图片。"
        case .screenRecordingPermissionRequired:
            return "无法读取其他应用的屏幕内容。请在系统设置 > 隐私与安全性 > 屏幕录制中允许“截图Free”，然后退出并重新打开应用。"
        }
    }
}

final class ScreenCaptureService {
    private let captureLock = NSLock()
    // 注入系统边界，测试无需屏幕权限或读取用户桌面。
    private let hasScreenAccess: () -> Bool
    private let currentDisplays: () -> [CaptureDisplay]
    private let captureDisplay: (CGDirectDisplayID) -> CGImage?
    private let captureQuartzRect: (CGRect) -> CGImage?
    private let windowList: () -> [[String: Any]]?
    private let captureWindows: (CGRect, [CGWindowID]) -> CGImage?

    init(
        hasScreenAccess: @escaping () -> Bool = { ScreenPermissionChecker.canRecordScreen },
        currentDisplays: @escaping () -> [CaptureDisplay] = { CaptureDisplay.current() },
        captureDisplay: @escaping (CGDirectDisplayID) -> CGImage? = { CGDisplayCreateImage($0) },
        captureQuartzRect: @escaping (CGRect) -> CGImage? = {
            CGWindowListCreateImage($0, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        },
        windowList: @escaping () -> [[String: Any]]? = {
            CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        },
        captureWindows: @escaping (CGRect, [CGWindowID]) -> CGImage? = { rect, ids in
            // 此 API 的 CFArray 元素是原始窗口 ID 指针值，不是 CFNumber。
            var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
            let array = CFArrayCreate(nil, &pointers, pointers.count, nil)!
            return CGImage(windowListFromArrayScreenBounds: rect, windowArray: array, imageOption: [.bestResolution, .boundsIgnoreFraming])
        }
    ) {
        self.hasScreenAccess = hasScreenAccess
        self.currentDisplays = currentDisplays
        self.captureDisplay = captureDisplay
        self.captureQuartzRect = captureQuartzRect
        self.windowList = windowList
        self.captureWindows = captureWindows
    }

    struct Tile {
        let frame: CGRect
        let image: CGImage
    }

    func capture(rect: CGRect) throws -> NSImage {
        let cgImage = try captureCGImage(rect: rect)
        return NSImage(cgImage: cgImage, size: rect.size)
    }

    func captureFullScreen() throws -> NSImage {
        let displays = currentDisplays()
        guard let first = displays.first else { throw ScreenCaptureError.failed }
        let rect = displays.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        return NSImage(cgImage: try captureCGImage(rect: rect, displays: displays), size: rect.size)
    }

    func captureCGImage(rect: CGRect, excludingWindowIDs: Set<CGWindowID> = []) throws -> CGImage {
        captureLock.lock()
        defer { captureLock.unlock() }
        try Task.checkCancellation()
        return try captureCGImage(rect: rect, displays: currentDisplays(), excludingWindowIDs: excludingWindowIDs)
    }

    static func includedWindowIDs(_ windows: [[String: Any]], excluding: Set<CGWindowID>, ownerPID: Int32) throws -> [CGWindowID] {
        try windows.map { info in
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32 else { throw ScreenCaptureError.failed }
            // 即使 ID 已被复用，也绝不排除其他应用的目标窗口。
            return excluding.contains(id) && pid == ownerPID ? nil : id
        }.compactMap { $0 }
    }

    private func captureCGImage(rect: CGRect, displays: [CaptureDisplay], excludingWindowIDs: Set<CGWindowID> = []) throws -> CGImage {
        guard CaptureGeometry.isValid(rect), let primary = displays.first else { throw ScreenCaptureError.failed }
        let intersecting = displays.filter { !$0.frame.intersection(rect).isEmpty }
        guard !intersecting.isEmpty else { throw ScreenCaptureError.failed }
        // 未授权时 Quartz 仍可能返回桌面/本应用窗口，非 nil 不代表捕获到目标内容。
        guard hasScreenAccess() else { throw ScreenCaptureError.screenRecordingPermissionRequired }
        var included: [CGWindowID]?
        if !excludingWindowIDs.isEmpty {
            guard let windows = windowList() else { throw ScreenCaptureError.failed }
            included = try Self.includedWindowIDs(windows, excluding: excludingWindowIDs, ownerPID: ProcessInfo.processInfo.processIdentifier)
            guard included?.isEmpty == false else { throw ScreenCaptureError.failed }
        }
        var tiles: [Tile] = []
        for display in intersecting {
            // 按整屏回退，再统一合成；不能在某一屏失败时返回整个选区的异尺度图片。
            let image: CGImage
            if let included {
                let quartzRect = CaptureGeometry.quartzRect(display.frame, primaryFrame: primary.frame)
                // 排除路径失败即显式失败；禁止回退到包含浮层的整屏截图。
                guard let captured = captureWindows(quartzRect, included) else { throw ScreenCaptureError.failed }
                image = captured
            } else if let captured = captureDisplay(display.id) {
                image = captured
            } else {
                let quartzRect = CaptureGeometry.quartzRect(display.frame, primaryFrame: primary.frame)
                guard let fallback = captureQuartzRect(quartzRect) else { throw ScreenCaptureError.failed }
                image = fallback
                AppLogger.log("display capture fallback display=\(display.id) quartzRect=\(quartzRect) pixels=\(image.width)x\(image.height)")
            }
            tiles.append(Tile(frame: display.frame, image: image))
        }
        return try Self.compose(rect: rect, tiles: tiles)
    }

    /// 混合 DPI 统一到相交屏幕中最高实际像素比例，低 DPI 屏幕上采样，绝不压低 Retina 分辨率。
    static func compose(rect: CGRect, tiles: [Tile]) throws -> CGImage {
        guard CaptureGeometry.isValid(rect) else { throw ScreenCaptureError.failed }
        let visible = tiles.filter { CaptureGeometry.isValid($0.frame) && !$0.frame.intersection(rect).isEmpty }
        guard !visible.isEmpty else { throw ScreenCaptureError.failed }
        let scale = visible.reduce(CGFloat(0)) {
            max($0, CGFloat($1.image.width) / $1.frame.width, CGFloat($1.image.height) / $1.frame.height)
        }
        let width = ceil(rect.width * scale)
        let height = ceil(rect.height * scale)
        // 防止无效尺寸转换溢出；内存不足交由 CGContext 返回失败。
        guard width.isFinite, height.isFinite, width < CGFloat(Int.max), height < CGFloat(Int.max),
              width * height <= CGFloat(Int.max / 4) else { throw ScreenCaptureError.failed }
        // cropping 的子图可能持有整屏 backing；长截图长期保存时必须复制到选区大小的 context。
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenCaptureError.failed }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        for tile in visible {
            context.saveGState()
            let intersection = tile.frame.intersection(rect).offsetBy(dx: -rect.minX, dy: -rect.minY)
            context.clip(to: intersection)
            context.draw(tile.image, in: tile.frame.offsetBy(dx: -rect.minX, dy: -rect.minY))
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw ScreenCaptureError.failed }
        return image
    }
}
