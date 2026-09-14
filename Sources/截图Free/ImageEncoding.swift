import AppKit

enum ImageEncoding {
    /// 不用 NSImage.size（点）推测像素，也不依赖当前显示器的 backingScaleFactor。
    static func sourceCGImage(from image: NSImage) -> CGImage? {
        if let representation = image.representations
            .filter({ $0.pixelsWide > 0 && $0.pixelsHigh > 0 })
            .max(by: { Double($0.pixelsWide) * Double($0.pixelsHigh) < Double($1.pixelsWide) * Double($1.pixelsHigh) }) {
            if let bitmap = representation as? NSBitmapImageRep, let cgImage = bitmap.cgImage {
                return cgImage
            }
            var rect = CGRect(origin: .zero, size: CGSize(width: representation.pixelsWide, height: representation.pixelsHigh))
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func pngData(from image: NSImage) throws -> Data {
        guard let cgImage = sourceCGImage(from: image),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.imageEncodingFailed
        }
        return data
    }
}
