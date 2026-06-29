import AppKit

enum ImageEncoding {
    static func pngData(from image: NSImage) throws -> Data {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.imageEncodingFailed
        }
        return data
    }
}
