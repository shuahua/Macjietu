import AppKit
import XCTest
@testable import 截图Free

private final class FakeShortcutRegistration: ShortcutRegistration {
    var fails = false
    var shortcut: Shortcut?
    var handler: (() -> Void)?
    var removed = false
    func register(shortcut: Shortcut, handler: @escaping () -> Void) {
        self.shortcut = shortcut
        self.handler = handler
    }
    func unregister() { removed = true }
    func status(for shortcut: Shortcut) -> ShortcutManager.RegistrationStatus? {
        .init(shortcut: shortcut, isRegistered: !fails && !removed, errorCode: fails ? -9878 : nil)
    }
}

@MainActor
final class SettingsShortcutCustomizationTests: XCTestCase {
    private func store() -> SettingsStore { SettingsStore(fileURL: temporaryURL().appendingPathComponent("settings.json")) }

    func testLegacyMappingAndClearSurvivesRoundTrip() throws {
        var legacy = AppSettings.defaults
        let custom = Shortcut(keyCode: 17, modifierFlags: [.option, .command])
        legacy.captureShortcut = custom
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded.shortcut(for: .area), custom)
        XCTAssertEqual(decoded.shortcut(for: .window), .defaultWindowCapture)
        XCTAssertEqual(decoded.shortcut(for: .fullScreen), .defaultFullScreenCapture)
        XCTAssertEqual(decoded.shortcut(for: .automaticLong), .defaultLongCapture)
        XCTAssertNil(decoded.shortcut(for: .manualLong))
        XCTAssertNil(decoded.shortcut(for: .recording))
        let storage = store()
        for action in ShortcutAction.allCases { legacy.setShortcut(nil, for: action) }
        try storage.save(legacy)
        for action in ShortcutAction.allCases { XCTAssertNil(storage.load().shortcut(for: action)) }
        XCTAssertEqual(storage.load().shortcuts, [:])
    }

    func testRegistrationFailureDuplicateAndWriteFailureKeepOldValues() throws {
        let storage = store()
        try storage.save(.defaults)
        var fakes: [FakeShortcutRegistration] = []
        var fail = false
        let bindings = ShortcutBindings(store: storage, factory: {
            let fake = FakeShortcutRegistration(); fake.fails = fail; fakes.append(fake); return fake
        })
        bindings.start()
        let old = storage.load()
        XCTAssertNotNil(bindings.update(.defaultWindowCapture, for: .area))
        XCTAssertEqual(fakes.count, 4)
        fail = true
        XCTAssertNotNil(bindings.update(Shortcut(keyCode: 17, modifierFlags: .option), for: .area))
        XCTAssertEqual(storage.load(), old)
        XCTAssertFalse(fakes[0].removed)
        fail = false
        let custom = Shortcut(keyCode: 17, modifierFlags: .option)
        XCTAssertNil(bindings.update(custom, for: .recording))
        XCTAssertEqual(storage.load().shortcut(for: .recording), custom)
        XCTAssertNil(bindings.update(nil, for: .area))
        XCTAssertNil(storage.load().shortcut(for: .area))
        bindings.start()
        XCTAssertEqual(storage.load().shortcut(for: .recording), custom)

        // 以目录作为文件地址制造确定性写失败，不碰用户配置。
        let bad = SettingsStore(fileURL: temporaryURL())
        let rollback = ShortcutBindings(store: bad, factory: { FakeShortcutRegistration() })
        rollback.start()
        XCTAssertNotNil(rollback.update(custom, for: .area))
        XCTAssertEqual(bad.load(), .defaults)
    }

    func testSixDispatchAndSuspensionRejectStaleCallbacks() throws {
        let storage = store()
        var settings = AppSettings.defaults
        settings.setShortcut(Shortcut(keyCode: 122, modifierFlags: []), for: .manualLong)
        settings.setShortcut(Shortcut(keyCode: 120, modifierFlags: []), for: .recording)
        try storage.save(settings)
        var fakes: [FakeShortcutRegistration] = []
        var actions: [ShortcutAction] = []
        let bindings = ShortcutBindings(store: storage, factory: {
            let fake = FakeShortcutRegistration(); fakes.append(fake); return fake
        }, dispatch: { actions.append($0) })
        bindings.start()
        let first = fakes
        first.forEach { $0.handler?() }
        XCTAssertEqual(actions, ShortcutAction.allCases)
        bindings.suspend()
        first.forEach { $0.handler?() }
        XCTAssertEqual(actions.count, 6)
        XCTAssertTrue(first.allSatisfy(\.removed))
        bindings.resume()
        first.forEach { $0.handler?() }
        XCTAssertEqual(actions.count, 6)
        fakes.last?.handler?()
        XCTAssertEqual(actions.last, .recording)
        XCTAssertEqual(actions.count, 7)
    }

    func testNavigationRecordingCancellationFocusAndPreciseAbout() throws {
        _ = NSApplication.shared
        let storage = store()
        let bindings = ShortcutBindings(store: storage, factory: { FakeShortcutRegistration() })
        bindings.start()
        let controller = SettingsWindowController(settingsStore: storage, bindings: bindings)
        let window = controller.makeWindow()
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        XCTAssertEqual(controller.selectedCategory, .general)
        controller.selectCategory(.shortcuts)
        let buttons = descendants(window.contentView!).compactMap { $0 as? NSButton }
        for action in ShortcutAction.allCases { XCTAssertTrue(buttons.contains { $0.title == action.title }) }
        XCTAssertEqual(buttons.filter { $0.title == "未设置" }.count, 2)
        controller.beginRecording(.recording)
        XCTAssertTrue(bindings.isSuspended)
        controller.receiveKey(keyCode: 55, modifiers: .command, isKeyDown: false)
        controller.receiveKey(keyCode: 0, modifiers: [])
        XCTAssertEqual(controller.recordingAction, .recording)
        controller.receiveKey(keyCode: 53, modifiers: [])
        XCTAssertNil(controller.recordingAction)
        XCTAssertFalse(bindings.isSuspended)
        controller.beginRecording(.area)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        XCTAssertNil(controller.recordingAction)
        XCTAssertFalse(bindings.isSuspended)
        controller.beginRecording(.recording)
        controller.receiveKey(keyCode: 17, modifiers: [.command, .option, .capsLock])
        XCTAssertEqual(storage.load().shortcut(for: .recording), Shortcut(keyCode: 17, modifierFlags: [.command, .option]))
        XCTAssertFalse(bindings.isSuspended)
        controller.beginRecording(.area)
        controller.selectCategory(.about)
        XCTAssertNil(controller.recordingAction)
        XCTAssertFalse(bindings.isSuspended)
        let labels = descendants(window.contentView!).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains("免费截图工具，全部由AI生成，sang。"))
        XCTAssertEqual(labels.filter { $0 != "设置" }, [SettingsWindowController.aboutText])
        window.close()
        let reopened = controller.makeWindow()
        defer { reopened.close() }
        controller.selectCategory(.general)
        let generalLabels = descendants(reopened.contentView!).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertFalse(generalLabels.contains(SettingsWindowController.aboutText))
        XCTAssertTrue(generalLabels.contains("截图导出尺寸"))
    }

    func testPhysicalKeyFormattingAndValidation() {
        XCTAssertEqual(Shortcut(keyCode: 17, modifierFlags: [.control, .option, .shift, .command, .capsLock]).displayString, "⌃⌥⇧⌘T")
        XCTAssertEqual(Shortcut(keyCode: 122, modifierFlags: []).displayString, "F1")
        XCTAssertEqual(Shortcut(keyCode: 123, modifierFlags: .option).displayString, "⌥←")
        XCTAssertFalse(Shortcut(keyCode: 0, modifierFlags: .shift).isValidGlobalShortcut)
        XCTAssertFalse(Shortcut(keyCode: 55, modifierFlags: .command).isValidGlobalShortcut)
        XCTAssertTrue(Shortcut(keyCode: 122, modifierFlags: []).isValidGlobalShortcut)
    }
}
