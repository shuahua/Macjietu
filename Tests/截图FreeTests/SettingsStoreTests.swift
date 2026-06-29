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
}
