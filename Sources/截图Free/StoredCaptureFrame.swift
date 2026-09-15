import AppKit

/// 不可变磁盘快照；计划的值类型副本共享文件生命周期，不共享可变目录。
final class StoredCaptureFrame {
    let url: URL
    let width: Int
    let height: Int
    let byteCount: Int

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        url = FileManager.default.temporaryDirectory.appendingPathComponent("long-frame-\(UUID().uuidString).rgba")
        byteCount = width * height * 4
        // 规范 RGBA 原始像素避免 PNG 色彩配置往返引入舍入差异；不保留 context。
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else {
            throw LongScreenshotError.noFramesCaptured
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        do {
            // 同步写入期间 context 存活，无需再复制一张完整 RGBA 到 Data。
            try Data(bytesNoCopy: data, count: byteCount, deallocator: .none).write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func load() throws -> CGImage {
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        guard data.count == byteCount, let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw LongScreenshotError.noFramesCaptured
        }
        return image
    }

    deinit {
        do { try FileManager.default.removeItem(at: url) }
        catch { AppLogger.log("long frame cleanup failed: \(error.localizedDescription)") }
    }
}
