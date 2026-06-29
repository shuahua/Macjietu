import Foundation

enum RecordingQuality: String, CaseIterable {
    case standard
    case high
    case original

    var title: String {
        switch self {
        case .standard: "标清"
        case .high: "高清"
        case .original: "原画"
        }
    }

    var outputScale: Double {
        switch self {
        case .standard: 0.75
        case .high: 1
        case .original: 1
        }
    }

    func bitRate(width: Int, height: Int) -> Int {
        let pixels = width * height
        let base = max(12_000_000, pixels * 12)
        switch self {
        case .standard:
            return base
        case .high:
            return base * 2
        case .original:
            return base * 4
        }
    }
}
