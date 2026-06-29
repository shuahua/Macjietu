import Foundation

struct AppSettings: Codable, Equatable {
    var captureShortcut: Shortcut
    var autoCopyAfterCapture: Bool
    var launchAtLogin: Bool
    var saveDirectory: URL?
    var exportScale: Double

    static let defaults = AppSettings(
        captureShortcut: .defaultCapture,
        autoCopyAfterCapture: false,
        launchAtLogin: false,
        saveDirectory: nil,
        exportScale: 2
    )

    init(captureShortcut: Shortcut, autoCopyAfterCapture: Bool, launchAtLogin: Bool, saveDirectory: URL?, exportScale: Double) {
        self.captureShortcut = captureShortcut
        self.autoCopyAfterCapture = autoCopyAfterCapture
        self.launchAtLogin = launchAtLogin
        self.saveDirectory = saveDirectory
        self.exportScale = exportScale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureShortcut = try container.decode(Shortcut.self, forKey: .captureShortcut)
        autoCopyAfterCapture = try container.decode(Bool.self, forKey: .autoCopyAfterCapture)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? Self.defaults.launchAtLogin
        saveDirectory = try container.decodeIfPresent(URL.self, forKey: .saveDirectory)
        exportScale = try container.decodeIfPresent(Double.self, forKey: .exportScale) ?? Self.defaults.exportScale
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
