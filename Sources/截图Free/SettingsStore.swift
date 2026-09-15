import Foundation

enum ScreenshotExportScale: Double, CaseIterable {
    case original = 1, double = 2, triple = 3

    var title: String {
        switch self {
        case .original: "原始像素（推荐）"
        case .double: "2 倍像素（插值放大）"
        case .triple: "3 倍像素（插值放大）"
        }
    }

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite, value >= 1 else { return 1 }
        return min(3, value.rounded())
    }
}

struct AppSettings: Codable, Equatable {
    var captureShortcut: Shortcut
    var autoCopyAfterCapture: Bool
    var launchAtLogin: Bool
    var saveDirectory: URL?
    var exportScale: Double
    // 缺少整个字典才是旧格式；字典中缺项表示明确清除，不补默认。
    var shortcuts: [String: Shortcut]? = nil

    func shortcut(for action: ShortcutAction) -> Shortcut? {
        if let shortcuts { return shortcuts[action.rawValue] }
        return action == .area ? captureShortcut : action.legacyDefault
    }

    mutating func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        if shortcuts == nil {
            shortcuts = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.compactMap { action in
                self.shortcut(for: action).map { (action.rawValue, $0) }
            })
        }
        shortcuts?[action.rawValue] = shortcut
        if action == .area, let shortcut { captureShortcut = shortcut }
    }

    static let defaults = AppSettings(
        captureShortcut: .defaultCapture,
        autoCopyAfterCapture: false,
        launchAtLogin: false,
        saveDirectory: nil,
        exportScale: 1
    )

    init(captureShortcut: Shortcut, autoCopyAfterCapture: Bool, launchAtLogin: Bool, saveDirectory: URL?, exportScale: Double) {
        self.captureShortcut = captureShortcut
        self.autoCopyAfterCapture = autoCopyAfterCapture
        self.launchAtLogin = launchAtLogin
        self.saveDirectory = saveDirectory
        self.exportScale = ScreenshotExportScale.normalized(exportScale)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureShortcut = try container.decode(Shortcut.self, forKey: .captureShortcut)
        shortcuts = try container.decodeIfPresent([String: Shortcut].self, forKey: .shortcuts)
        autoCopyAfterCapture = try container.decode(Bool.self, forKey: .autoCopyAfterCapture)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? Self.defaults.launchAtLogin
        saveDirectory = try container.decodeIfPresent(URL.self, forKey: .saveDirectory)
        // 保留旧 1/2/3 的选择，已移除的 4/5 收敛到 3；缺失字段推荐原始。
        exportScale = ScreenshotExportScale.normalized(
            try container.decodeIfPresent(Double.self, forKey: .exportScale) ?? Self.defaults.exportScale)
    }
}

final class SettingsStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? decoder.decode(AppSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
