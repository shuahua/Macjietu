import AppKit
import Foundation

enum SystemScreenshotError: LocalizedError {
    case cancelled
    case failed(Int32)
    case timedOut
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "已取消截图。"
        case let .failed(code):
            return "系统截图命令失败，退出码：\(code)。"
        case .timedOut:
            return "系统截图命令超时。"
        case .unreadableImage:
            return "无法读取系统截图结果。"
        }
    }
}

final class SystemScreenshotService {
    func captureInteractive() async throws -> NSImage {
        try await capture(arguments: ["-i"], timeout: nil)
    }

    func captureWindow() async throws -> NSImage {
        try await capture(arguments: ["-i", "-w", "-o"], timeout: nil)
    }

    func captureFullScreen() async throws -> NSImage {
        // screencapture 每屏输出一个文件；单文件读取会静默丢弃副屏并遗留临时文件。
        // 改为按桌面布局合成一张保留最高像素比例的图片。
        try ScreenCaptureService().captureFullScreen()
    }

    func captureRegion(rect: CGRect) async throws -> NSImage {
        // 与覆盖层统一接收 AppKit 点坐标，避免 -R 的原点差异及负坐标 Int 截断。
        try ScreenCaptureService().capture(rect: rect)
    }

    private func capture(arguments: [String], timeout: TimeInterval?) async throws -> NSImage {
        let fileURL = try await captureFile(arguments: arguments, timeout: timeout)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = NSImage(contentsOf: fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw SystemScreenshotError.cancelled
        }
        try? FileManager.default.removeItem(at: fileURL)
        return image
    }

    private func captureFile(arguments: [String], timeout: TimeInterval?) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("截图Free-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("capture.png")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments + [fileURL.path]

            var shouldKeepFile = false
            defer {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
                if !shouldKeepFile {
                    try? FileManager.default.removeItem(at: directory)
                }
            }

            try Task.checkCancellation()
            try process.run()
            // 交互截图等待用户确认或按 Esc，不限制思考和选区时间。
            let deadline = timeout.map { Date().addingTimeInterval($0) }
            while process.isRunning {
                if let deadline, Date() >= deadline { break }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 30_000_000)
            }

            if process.isRunning {
                process.terminate()
                AppLogger.log("screencapture timed out arguments=\(arguments)")
                throw SystemScreenshotError.timedOut
            }

            AppLogger.log("screencapture exited status=\(process.terminationStatus) arguments=\(arguments)")

            if process.terminationStatus != 0 {
                if process.terminationStatus == 1 {
                    throw SystemScreenshotError.cancelled
                }
                throw SystemScreenshotError.failed(process.terminationStatus)
            }

            shouldKeepFile = true
            return fileURL
        }.value
    }
}
