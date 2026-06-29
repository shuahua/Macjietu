import Foundation

enum VideoFileNamer {
    static func fileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "录屏 " + formatter.string(from: date) + ".mov"
    }
}
