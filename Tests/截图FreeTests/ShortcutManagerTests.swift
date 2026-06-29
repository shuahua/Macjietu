import Carbon.HIToolbox
import XCTest
@testable import 截图Free

final class ShortcutManagerTests: XCTestCase {
    func testRegistrationStatusDisplaySuffix() {
        let shortcut = Shortcut(keyCode: 1, modifierFlags: [.command, .shift])
        let registered = ShortcutManager.RegistrationStatus(shortcut: shortcut, isRegistered: true, errorCode: nil)
        let unavailable = ShortcutManager.RegistrationStatus(shortcut: shortcut, isRegistered: false, errorCode: OSStatus(eventHotKeyExistsErr))

        XCTAssertEqual(registered.displaySuffix, "")
        XCTAssertEqual(unavailable.displaySuffix, "（冲突或不可用）")
    }

    func testCommonAppShortcutConflictIsMarked() {
        let commonConflict = Shortcut(keyCode: 13, modifierFlags: [.command, .shift])
        let status = ShortcutManager.RegistrationStatus(shortcut: commonConflict, isRegistered: true, errorCode: nil)

        XCTAssertEqual(status.displaySuffix, "（常用快捷键冲突）")
    }
}
