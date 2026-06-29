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
        try await capture(arguments: ["-i"], timeout: 60)
    }

    func captureWindow() async throws -> NSImage {
        try await capture(arguments: ["-i", "-w", "-o"], timeout: 60)
    }

    func captureFullScreen() async throws -> NSImage {
        try await capture(arguments: [], timeout: 8)
    }

    func captureRegion(rect: CGRect) async throws -> NSImage {
        let fileURL = try await captureFile(arguments: ["-R", "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.size.width)),\(Int(rect.size.height))"], timeout: 8)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = NSImage(contentsOf: fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw SystemScreenshotError.cancelled
        }
        try? FileManager.default.removeItem(at: fileURL)
        return image
    }

    private func capture(arguments: [String], timeout: TimeInterval) async throws -> NSImage {
        let fileURL = try await captureFile(arguments: arguments, timeout: timeout)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = NSImage(contentsOf: fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw SystemScreenshotError.cancelled
        }
        try? FileManager.default.removeItem(at: fileURL)
        return image
    }

    private func captureFile(arguments: [String], timeout: TimeInterval) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("截图Free-\(UUID().uuidString).png")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments + [fileURL.path]

            var shouldKeepFile = false
            defer {
                if process.isRunning {
                    process.terminate()
                }
                if !shouldKeepFile {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }

            try Task.checkCancellation()
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
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
