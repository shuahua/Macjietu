import AppKit

enum ClipboardService {
    static func copy(image: NSImage) {
        do {
            let data = try ImageEncoding.pngData(from: image)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        } catch {
            AppLogger.log("copy image failed: \(error.localizedDescription)")
        }
    }
}
