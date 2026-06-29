import AppKit
import CoreGraphics

enum ScreenCaptureError: LocalizedError {
    case failed
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .failed:
            return "无法捕获选中区域。"
        case .imageEncodingFailed:
            return "无法编码图片。"
        }
    }
}

final class ScreenCaptureService {
    func capture(rect: CGRect) throws -> NSImage {
        let cgImage = try captureCGImage(rect: rect)
        return NSImage(cgImage: cgImage, size: rect.size)
    }

    func captureCGImage(rect: CGRect) throws -> CGImage {
        if let displayImage = captureDisplayCGImage(rect: rect) {
            return displayImage
        }

        guard let cgImage = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
            throw ScreenCaptureError.failed
        }
        return cgImage
    }

    private func captureDisplayCGImage(rect: CGRect) -> CGImage? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else { return nil }
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = screen.deviceDescription[screenNumberKey] as? CGDirectDisplayID else { return nil }

        let backingScale = screen.backingScaleFactor
        let localRect = CGRect(
            x: (rect.minX - screen.frame.minX) * backingScale,
            y: (screen.frame.maxY - rect.maxY) * backingScale,
            width: rect.width * backingScale,
            height: rect.height * backingScale
        ).integral

        AppLogger.log("display capture rect=\(rect) screen=\(screen.frame) scale=\(backingScale) local=\(localRect)")
        return CGDisplayCreateImage(displayID, rect: localRect)
    }
}
