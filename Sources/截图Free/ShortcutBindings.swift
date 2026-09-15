import AppKit

/// 注册边界可注入，测试不占用系统热键、不发送键盘事件。
protocol ShortcutRegistration: AnyObject {
    func register(shortcut: Shortcut, handler: @escaping () -> Void)
    func unregister()
    func status(for shortcut: Shortcut) -> ShortcutManager.RegistrationStatus?
}
extension ShortcutManager: ShortcutRegistration {}

@MainActor
final class ShortcutBindings {
    private let store: SettingsStore
    private let factory: () -> ShortcutRegistration
    private var registrations: [ShortcutAction: ShortcutRegistration] = [:]
    private let dispatch: (ShortcutAction) -> Void
    private(set) var isSuspended = false
    private(set) var generation = 0
    private(set) var recoveryWarning: String?
    var onChange: (() -> Void)?

    init(store: SettingsStore, factory: @escaping () -> ShortcutRegistration = { ShortcutManager() },
         dispatch: @escaping (ShortcutAction) -> Void = { _ in }) {
        self.store = store
        self.factory = factory
        self.dispatch = dispatch
    }

    func start() {
        stop()
        isSuspended = false
        recoveryWarning = nil
        let settings = store.load()
        for action in ShortcutAction.allCases {
            guard let shortcut = settings.shortcut(for: action) else { continue }
            let registration = factory()
            register(registration, shortcut: shortcut, action: action)
            registrations[action] = registration
            if registration.status(for: shortcut)?.isRegistered != true {
                recoveryWarning = "部分快捷键冲突或不可用，请在快捷键设置中检查。"
            }
        }
    }

    private func register(_ registration: ShortcutRegistration, shortcut: Shortcut, action: ShortcutAction) {
        let epoch = generation
        registration.register(shortcut: shortcut) { [weak self] in
            // Carbon 在主事件循环调用；同步门禁避免录入前排队的 Task 延后启动截图。
            MainActor.assumeIsolated {
                guard let self, !self.isSuspended, self.generation == epoch else { return }
                self.dispatch(action)
            }
        }
    }

    func stop() {
        generation += 1
        registrations.values.forEach { $0.unregister() }
        registrations.removeAll()
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        stop()
    }

    func resume() {
        guard isSuspended else { return }
        start()
    }

    func display(for action: ShortcutAction) -> String {
        guard let shortcut = store.load().shortcut(for: action) else { return "未设置" }
        let failed = !isSuspended && registrations[action]?.status(for: shortcut)?.isRegistered != true
        return shortcut.displayString + (failed ? "（冲突或不可用）" : "")
    }

    /// 先保留旧注册，探测新注册，再原子写盘；任何失败都不会覆盖旧配置和其他动作。
    func update(_ shortcut: Shortcut?, for action: ShortcutAction) -> String? {
        resume()
        var settings = store.load()
        if let shortcut {
            guard shortcut.isValidGlobalShortcut else { return "请使用 ⌘、⌥、⌃ 至少一个修饰键，或 F1–F20。" }
            if let conflict = ShortcutAction.allCases.first(where: { $0 != action && settings.shortcut(for: $0) == shortcut }) {
                return "与“\(conflict.title)”重复，已保留原绑定。"
            }
        }
        if settings.shortcut(for: action) == shortcut,
           shortcut == nil || registrations[action]?.status(for: shortcut!)?.isRegistered == true { return nil }
        var candidate: ShortcutRegistration?
        if let shortcut {
            let registration = factory()
            register(registration, shortcut: shortcut, action: action)
            guard registration.status(for: shortcut)?.isRegistered == true else {
                let code = registration.status(for: shortcut)?.errorCode ?? -1
                registration.unregister()
                return "系统或其他应用占用，或组合不可注册（\(code)）；已保留原绑定。"
            }
            candidate = registration
        }
        settings.setShortcut(shortcut, for: action)
        do { try store.save(settings) }
        catch {
            candidate?.unregister()
            return "保存失败，已保留原绑定：\(error.localizedDescription)"
        }
        registrations[action]?.unregister()
        registrations[action] = candidate
        onChange?()
        return nil
    }
}
