import Foundation

enum AppLogger {
    private static var logURL: URL {
        FileManager.default.applicationSupportDirectory
            .appendingPathComponent("截图Free", isDirectory: true)
            .appendingPathComponent("app.log")
    }

    static func log(_ message: String) {
        let line = "\(Date().formatted(date: .numeric, time: .standard)) \(message)\n"
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } else {
                try line.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
        }
    }
}
