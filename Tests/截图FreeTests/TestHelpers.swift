import Foundation

func temporaryURL(function: String = #function) -> URL {
    let sanitized = function.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("截图FreeTests", isDirectory: true)
        .appendingPathComponent(sanitized + "-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
