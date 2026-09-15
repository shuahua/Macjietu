import AppKit

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    enum Category: String, CaseIterable { case general = "通用", shortcuts = "快捷键", about = "关于" }
    static let aboutText = "免费截图工具，全部由AI生成，sang。"
    private(set) var selectedCategory: Category = .general
    private(set) var recordingAction: ShortcutAction?
    private let bindings: ShortcutBindings?
    private let detail = SettingsBodyView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var navigation: [NSButton] = []
    private var keyMonitor: Any?
    private let settingsStore: SettingsStore
    private var window: NSWindow?
    private let autoCopyButton = GlassButton(checkboxWithTitle: "截图后自动复制到剪贴板", target: nil, action: nil)
    private let launchAtLoginButton = GlassButton(checkboxWithTitle: "开机自动启动", target: nil, action: nil)
    private let exportScalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let exportScaleOptions = ScreenshotExportScale.allCases

    init(settingsStore: SettingsStore, bindings: ShortcutBindings? = nil) {
        self.settingsStore = settingsStore
        self.bindings = bindings
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = makeWindow()
        window.center()
        window.makeKeyAndOrderFront(nil)
        GlassMotion.reveal(window.contentView)
        NSApp.activate(ignoringOtherApps: true)
    }

    // 与显示分离，允许不激活应用、不请求屏幕权限地检查真实 AppKit 布局。
    func makeWindow() -> NSWindow {
        if let window { return window }
        detail.subviews.forEach { $0.removeFromSuperview() }
        let settings = settingsStore.load()
        let contentView = GlassView(frame: CGRect(x: 0, y: 0, width: 740, height: 480))
        contentView.dragsWindowOnBackground = true
        let body = SettingsBodyView(frame: CGRect(x: 0, y: 0, width: 740, height: 440))
        body.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(body)

        let title = NSTextField(labelWithString: "设置")
        title.font = .boldSystemFont(ofSize: 18)
        title.textColor = .labelColor
        title.frame = CGRect(x: 20, y: 398, width: 140, height: 28)
        body.addSubview(title)
        navigation = Category.allCases.enumerated().map { index, category in
            let button = GlassButton(title: category.rawValue, target: self, action: #selector(categoryClicked(_:)))
            button.tag = index
            button.setButtonType(.toggle)
            button.bezelStyle = .rounded
            button.useSidebarSurface()
            button.frame = CGRect(x: 16, y: 338 - index * 48, width: 136, height: 36)
            body.addSubview(button)
            return button
        }
        detail.frame = CGRect(x: 176, y: 0, width: 544, height: 390)
        detail.identifier = NSUserInterfaceItemIdentifier("settings-detail")
        body.addSubview(detail)
        let divider = SettingsSidebarDivider(frame: CGRect(x: 164, y: 20, width: 1, height: 366))
        body.addSubview(divider)

        autoCopyButton.state = settings.autoCopyAfterCapture ? .on : .off
        autoCopyButton.frame = CGRect(x: 20, y: 122, width: 260, height: 24)
        autoCopyButton.target = self
        autoCopyButton.action = #selector(settingsChanged)
        detail.addSubview(autoCopyButton)

        launchAtLoginButton.state = settings.launchAtLogin || LoginItemService.isEnabled ? .on : .off
        launchAtLoginButton.frame = CGRect(x: 20, y: 90, width: 260, height: 24)
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(settingsChanged)
        detail.addSubview(launchAtLoginButton)

        let qualityLabel = NSTextField(labelWithString: "截图导出尺寸")
        qualityLabel.frame = CGRect(x: 20, y: 54, width: 80, height: 22)
        qualityLabel.textColor = .labelColor
        detail.addSubview(qualityLabel)

        exportScalePopup.removeAllItems()
        exportScalePopup.addItems(withTitles: exportScaleOptions.map(\.title))
        exportScalePopup.frame = CGRect(x: 106, y: 50, width: 290, height: 28)
        let selectedIndex = exportScaleOptions.firstIndex { $0.rawValue == settings.exportScale } ?? 0
        exportScalePopup.selectItem(at: selectedIndex)
        exportScalePopup.target = self
        exportScalePopup.action = #selector(settingsChanged)
        detail.addSubview(exportScalePopup)

        let hint = NSTextField(labelWithString: "按源像素保存/复制；放大不增加截图细节，不影响录屏。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = CGRect(x: 20, y: 20, width: 390, height: 20)
        detail.addSubview(hint)
        // 保留通用页面的控件实例与行为；分类内容切换仅更换挂载。
        generalViews = detail.subviews
        for view in generalViews { view.frame.origin.y += 190 }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 740, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "截图Free 设置"
        window.titleVisibility = .hidden
        window.isMovable = true
        window.isMovableByWindowBackground = true
        GlassView.prepareWindow(window)
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        // fullSizeContentView 的根视图延伸进标题栏；正文只使用系统安全区。
        let guide = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            body.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            body.heightAnchor.constraint(equalToConstant: 440)
        ])
        contentView.layoutSubtreeIfNeeded()
        let titlebarHeight = contentView.bounds.height - window.contentLayoutRect.height
        var frame = window.frame
        frame.size.height = 440 + 8 + titlebarHeight
        window.setFrame(frame, display: false)
        contentView.layoutSubtreeIfNeeded()
        window.delegate = self
        self.window = window
        selectCategory(selectedCategory)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        cancelRecording()
        window?.delegate = nil
        window = nil
    }

    @objc private func settingsChanged() {
        saveCurrentSettings()
    }

    private func saveCurrentSettings() {
        var settings = settingsStore.load()
        settings.autoCopyAfterCapture = autoCopyButton.state == .on
        settings.launchAtLogin = launchAtLoginButton.state == .on
        settings.exportScale = exportScaleOptions[max(0, exportScalePopup.indexOfSelectedItem)].rawValue

        do {
            try LoginItemService.setEnabled(settings.launchAtLogin)
            try settingsStore.save(settings)
            AppLogger.log("settings saved autoCopyAfterCapture=\(settings.autoCopyAfterCapture) launchAtLogin=\(settings.launchAtLogin)")
        } catch {
            launchAtLoginButton.state = LoginItemService.isEnabled ? .on : .off
            AppLogger.log("settings save failed: \(error.localizedDescription)")
        }
    }

    private var generalViews: [NSView] = []

    @objc private func categoryClicked(_ sender: NSButton) {
        selectCategory(Category.allCases[sender.tag])
    }

    func selectCategory(_ category: Category) {
        cancelRecording()
        selectedCategory = category
        for (index, button) in navigation.enumerated() {
            button.state = Category.allCases[index] == category ? .on : .off
        }
        renderDetail()
    }

    private func renderDetail() {
        detail.subviews.forEach { $0.removeFromSuperview() }
        switch selectedCategory {
        case .general: generalViews.forEach { detail.addSubview($0) }
        case .about:
            let label = NSTextField(wrappingLabelWithString: Self.aboutText)
            label.font = .systemFont(ofSize: 18)
            label.frame = CGRect(x: 20, y: 260, width: 490, height: 80)
            detail.addSubview(label)
        case .shortcuts:
            for (index, action) in ShortcutAction.allCases.enumerated() {
                let y = 340 - index * 46
                let name = GlassButton(title: action.title, target: self, action: #selector(recordClicked(_:)))
                name.tag = index
                name.isBordered = false
                name.alignment = .left
                name.frame = CGRect(x: 12, y: y, width: 158, height: 34)
                detail.addSubview(name)
                let text = recordingAction == action ? "请按快捷键…" : (bindings?.display(for: action) ?? settingsStore.load().shortcut(for: action)?.displayString ?? "未设置")
                let record = GlassButton(title: text, target: self, action: #selector(recordClicked(_:)))
                record.tag = index
                record.bezelStyle = .rounded
                record.frame = CGRect(x: 172, y: y, width: 266, height: 34)
                record.setAccessibilityLabel("\(action.title)：\(text)，点击录入")
                detail.addSubview(record)
                let clear = GlassButton(title: "清除", target: self, action: #selector(clearClicked(_:)))
                clear.tag = index
                clear.bezelStyle = .rounded
                clear.frame = CGRect(x: 444, y: y, width: 64, height: 34)
                detail.addSubview(clear)
            }
            message.frame = CGRect(x: 20, y: 8, width: 490, height: 90)
            message.font = .systemFont(ofSize: 12)
            message.textColor = .secondaryLabelColor
            if message.stringValue.isEmpty {
                message.stringValue = "点击功能或按键按钮后按下组合键即可完成。Escape 取消；清除按钮解除绑定。使用 ⌘/⌥/⌃ 或功能键；键名按物理键位显示。"
            }
            detail.addSubview(message)
        }
    }

    @objc private func recordClicked(_ sender: NSButton) { beginRecording(ShortcutAction.allCases[sender.tag]) }
    @objc private func clearClicked(_ sender: NSButton) {
        cancelRecording()
        let action = ShortcutAction.allCases[sender.tag]
        message.stringValue = bindings?.update(nil, for: action) ?? "已清除“\(action.title)”绑定。"
        if bindings == nil { message.stringValue = "快捷键服务未连接，未修改绑定。" }
        renderDetail()
    }

    func beginRecording(_ action: ShortcutAction) {
        cancelRecording()
        guard selectedCategory == .shortcuts else { return }
        bindings?.suspend()
        recordingAction = action
        message.stringValue = "请按快捷键；Escape 取消。单独修饰键不会提交。"
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recordingAction != nil else { return event }
            guard event.window === self.window, self.window?.isKeyWindow == true else {
                self.cancelRecording()
                return event
            }
            self.receiveKey(keyCode: event.keyCode, modifiers: event.modifierFlags, isKeyDown: event.type == .keyDown,
                            isRepeat: event.type == .keyDown && event.isARepeat)
            return nil
        }
        renderDetail()
        window?.makeFirstResponder(window?.contentView)
    }

    func receiveKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isKeyDown: Bool = true, isRepeat: Bool = false) {
        guard let action = recordingAction, isKeyDown, !isRepeat else { return }
        if keyCode == 53 { cancelRecording(); return }
        let shortcut = Shortcut(keyCode: keyCode, modifierFlags: modifiers)
        guard shortcut.isValidGlobalShortcut else {
            message.stringValue = "请使用 ⌘、⌥、⌃ 至少一个修饰键，或 F1–F20；Escape 取消。"
            return
        }
        cancelRecording()
        message.stringValue = bindings?.update(shortcut, for: action) ?? "已保存，立即生效。"
        if bindings == nil { message.stringValue = "快捷键服务未连接，未修改绑定。" }
        renderDetail()
    }

    func cancelRecording() {
        let wasRecording = recordingAction != nil
        recordingAction = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        bindings?.resume()
        if wasRecording {
            message.stringValue = bindings?.recoveryWarning ?? "已停止录入。"
            renderDetail()
        }
    }

    func windowDidResignKey(_ notification: Notification) { cancelRecording() }
}

/// 装饰只绘制，不截获点击或玻璃根视图的窗口拖动。
final class SettingsSidebarDivider: NSView {
    var reduceTransparencyOverride: Bool?
    override init(frame: NSRect) {
        super.init(frame: frame)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAppearance),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func refreshAppearance() { needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var allowsVibrancy: Bool { false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let opaque = reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        (opaque ? NSColor.separatorColor.withAlphaComponent(1) : NSColor.separatorColor).setFill()
        bounds.fill()
    }
}

// 标签和正文留白交给玻璃根视图拖动，按钮仍保留正常命中与动作。
private final class SettingsBodyView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self || (hit as? NSTextField)?.isEditable == false { return nil }
        return hit
    }
}
