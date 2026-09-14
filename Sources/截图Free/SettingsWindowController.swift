import AppKit

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settingsStore: SettingsStore
    private var window: NSWindow?
    private let autoCopyButton = NSButton(checkboxWithTitle: "截图后自动复制到剪贴板", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "开机自动启动", target: nil, action: nil)
    private let exportScalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let exportScaleOptions = ScreenshotExportScale.allCases

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settings = settingsStore.load()
        let contentView = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 200))

        let title = NSTextField(labelWithString: "设置")
        title.font = .boldSystemFont(ofSize: 18)
        title.frame = CGRect(x: 20, y: 154, width: 360, height: 28)
        contentView.addSubview(title)

        autoCopyButton.state = settings.autoCopyAfterCapture ? .on : .off
        autoCopyButton.frame = CGRect(x: 20, y: 122, width: 260, height: 24)
        autoCopyButton.target = self
        autoCopyButton.action = #selector(settingsChanged)
        contentView.addSubview(autoCopyButton)

        launchAtLoginButton.state = settings.launchAtLogin || LoginItemService.isEnabled ? .on : .off
        launchAtLoginButton.frame = CGRect(x: 20, y: 90, width: 260, height: 24)
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(settingsChanged)
        contentView.addSubview(launchAtLoginButton)

        let qualityLabel = NSTextField(labelWithString: "截图导出尺寸")
        qualityLabel.frame = CGRect(x: 20, y: 54, width: 80, height: 22)
        contentView.addSubview(qualityLabel)

        exportScalePopup.removeAllItems()
        exportScalePopup.addItems(withTitles: exportScaleOptions.map(\.title))
        exportScalePopup.frame = CGRect(x: 106, y: 50, width: 290, height: 28)
        let selectedIndex = exportScaleOptions.firstIndex { $0.rawValue == settings.exportScale } ?? 0
        exportScalePopup.selectItem(at: selectedIndex)
        exportScalePopup.target = self
        exportScalePopup.action = #selector(settingsChanged)
        contentView.addSubview(exportScalePopup)

        let hint = NSTextField(labelWithString: "按源像素保存/复制；放大不增加截图细节，不影响录屏。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = CGRect(x: 20, y: 20, width: 390, height: 20)
        contentView.addSubview(hint)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "截图Free 设置"
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
    }

    @objc private func settingsChanged() {
        saveCurrentSettings()
    }

    private func saveCurrentSettings() {
        let settings = AppSettings(
            captureShortcut: settingsStore.load().captureShortcut,
            autoCopyAfterCapture: autoCopyButton.state == .on,
            launchAtLogin: launchAtLoginButton.state == .on,
            saveDirectory: nil,
            exportScale: exportScaleOptions[max(0, exportScalePopup.indexOfSelectedItem)].rawValue
        )

        do {
            try LoginItemService.setEnabled(settings.launchAtLogin)
            try settingsStore.save(settings)
            AppLogger.log("settings saved autoCopyAfterCapture=\(settings.autoCopyAfterCapture) launchAtLogin=\(settings.launchAtLogin)")
        } catch {
            launchAtLoginButton.state = LoginItemService.isEnabled ? .on : .off
            AppLogger.log("settings save failed: \(error.localizedDescription)")
        }
    }
}
