import AppKit
import XCTest
@testable import 截图Free

@MainActor
final class PermissionMenuTests: XCTestCase {
    func testEveryPermissionCombinationAndRefreshPreservesFunctionalEntries() {
        _ = NSApplication.shared
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
        var status = MenuPermissionStatus(screen: true, accessibility: true, microphone: true)
        var queries = 0
        let coordinator = AppCoordinator(captureService: ScreenCaptureService(),
            settingsStore: SettingsStore(fileURL: settingsURL), postLongScroll: { _, _ in },
            onLongImage: { _ in }, menuPermissions: { queries += 1; return status })
        let menu = NSMenu()
        // 同一个菜单连续刷新，覆盖授权、撤销授权及全授权后不遗留旧项目。
        for (iteration, mask) in (Array(0..<8) + [0, 7]).enumerated() {
            status = MenuPermissionStatus(screen: mask & 1 != 0,
                accessibility: mask & 2 != 0, microphone: mask & 4 != 0)
            coordinator.menuWillOpen(menu)
            XCTAssertEqual(queries, iteration + 1)
            let titles = menu.items.map(\.title)
            for (granted, title) in [(status.screen, "录屏权限：未开启"),
                                     (status.accessibility, "辅助功能权限：未开启"),
                                     (status.microphone, "麦克风权限：未开启")] {
                XCTAssertEqual(titles.contains(title), !granted)
                if let item = menu.items.first(where: { $0.title == title }) {
                    XCTAssertNil(item.action)
                    XCTAssertFalse(item.isEnabled)
                }
            }
            XCTAssertFalse(titles.contains { $0.contains("已开启") })
            for (granted, title, action) in [
                (status.screen, "请求屏幕录制权限", "requestScreenPermissionFromMenu"),
                (status.accessibility, "请求辅助功能权限", "requestAccessibilityPermissionFromMenu")
            ] {
                let item = menu.items.first { $0.title == title }
                XCTAssertEqual(item != nil, !granted)
                if let item {
                    XCTAssertEqual(item.action, NSSelectorFromString(action))
                    XCTAssertTrue(item.target === coordinator)
                }
            }
            for prefix in ["区域截图", "窗口截图", "全屏截图", "长截图自动滚动", "长截图手动滚动", "录屏", "设置", "退出"] {
                XCTAssertTrue(menu.items.contains { $0.title.hasPrefix(prefix) && $0.action != nil && $0.target === coordinator })
            }
            XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, mask == 7 ? 1 : 2)
            XCTAssertFalse(menu.items.first?.isSeparatorItem ?? true)
            XCTAssertFalse(menu.items.last?.isSeparatorItem ?? true)
            for (left, right) in zip(menu.items, menu.items.dropFirst()) {
                XCTAssertFalse(left.isSeparatorItem && right.isSeparatorItem)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }
}
