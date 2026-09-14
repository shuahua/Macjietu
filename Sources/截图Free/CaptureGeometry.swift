import AppKit

/// 所有公开截图选区均为 AppKit 全局坐标（点、左下原点）；只在系统 API 边界转换。
enum CaptureGeometry {
    static func quartzRect(_ rect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func quartzPoint(_ point: CGPoint, primaryFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x, y: primaryFrame.maxY - point.y)
    }

    static func isValid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }

    /// 使用捕获位图的真实尺寸，而不是假设 backingScaleFactor 等于截图像素比例。
    static func pixelRect(_ rect: CGRect, in frame: CGRect, pixels: CGSize) -> CGRect {
        let scaleX = pixels.width / frame.width
        let scaleY = pixels.height / frame.height
        return CGRect(x: (rect.minX - frame.minX) * scaleX,
                      y: (frame.maxY - rect.maxY) * scaleY,
                      width: rect.width * scaleX, height: rect.height * scaleY)
    }
}

struct CaptureDisplay {
    let id: CGDirectDisplayID
    let frame: CGRect

    static func current() -> [CaptureDisplay] {
        let read = {
            NSScreen.screens.compactMap { screen -> CaptureDisplay? in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
                return CaptureDisplay(id: id, frame: screen.frame)
            }
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }
}
