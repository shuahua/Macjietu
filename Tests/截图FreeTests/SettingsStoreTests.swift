import XCTest
@testable import 截图Free

final class SettingsStoreTests: XCTestCase {
    func testLoadReturnsDefaultsWhenFileDoesNotExist() {
        let store = SettingsStore(fileURL: temporaryURL().appendingPathComponent("missing.json"))

        XCTAssertEqual(store.load(), .defaults)
    }

    func testSaveAndLoadSettings() throws {
        let url = temporaryURL().appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: url)
        let settings = AppSettings(
            captureShortcut: Shortcut(keyCode: 8, modifierFlags: [.command, .option]),
            autoCopyAfterCapture: true,
            launchAtLogin: true,
            saveDirectory: URL(fileURLWithPath: "/tmp"),
            exportScale: 5
        )

        try store.save(settings)

        XCTAssertEqual(store.load(), settings)
    }

    func testDefaultLegacyAndInvalidScales() throws {
        XCTAssertEqual(AppSettings.defaults.exportScale, 1)
        XCTAssertEqual(ScreenshotExportScale.allCases.map(\.rawValue), [1, 2, 3])
        let encoded = try JSONEncoder().encode(AppSettings.defaults)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (old, expected) in [(1.0, 1.0), (2, 2), (3, 3), (4, 3), (5, 3), (0, 1), (-2, 1), (2.4, 2), (100, 3)] {
            json["exportScale"] = old
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.exportScale, expected)
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(decoded)), decoded)
        }
        json.removeValue(forKey: "exportScale")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json)).exportScale, 1)
        XCTAssertEqual(ScreenshotExportScale.normalized(.nan), 1)
        XCTAssertEqual(ScreenshotExportScale.normalized(.infinity), 1)
    }
}
