import Foundation

struct ScreenshotFileNamer {
    static func fileName(for date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = timeZone
        return "Screenshot-\(formatter.string(from: date)).png"
    }
}
