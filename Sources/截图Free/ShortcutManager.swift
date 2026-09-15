import AppKit
import Carbon.HIToolbox

final class ShortcutManager {
    // 多个独立注册器共用应用事件目标，ID 必须进程内唯一。
    private static var nextIdentifier: UInt32 = 1
    struct RegistrationStatus {
        let shortcut: Shortcut
        let isRegistered: Bool
        let errorCode: OSStatus?

        var displaySuffix: String {
            if !isRegistered { return "（冲突或不可用）" }
            if shortcut.hasCommonAppShortcutConflict { return "（常用快捷键冲突）" }
            return ""
        }
    }

    private var eventHandler: EventHandlerRef?
    private var registeredHotKeys: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private(set) var statuses: [RegistrationStatus] = []

    func register(shortcut: Shortcut, handler: @escaping () -> Void) {
        register(shortcuts: [(shortcut, handler)])
    }

    func register(shortcuts: [(Shortcut, () -> Void)]) {
        unregister()

        installEventHandlerIfNeeded()
        guard eventHandler != nil else {
            statuses = shortcuts.map { RegistrationStatus(shortcut: $0.0, isRegistered: false, errorCode: OSStatus(eventInternalErr)) }
            return
        }
        for item in shortcuts {
            let identifier = Self.nextIdentifier
            Self.nextIdentifier &+= 1
            var hotKeyRef: EventHotKeyRef?
            let signature = OSType(UInt32(0x53434E50))
            let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
            let status = RegisterEventHotKey(
                UInt32(item.0.keyCode),
                carbonModifiers(from: item.0.modifierFlags),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr, let hotKeyRef {
                registeredHotKeys.append(hotKeyRef)
                handlers[identifier] = item.1
                statuses.append(RegistrationStatus(shortcut: item.0, isRegistered: true, errorCode: nil))
                AppLogger.log("shortcut registered \(item.0.displayString)")
            } else {
                statuses.append(RegistrationStatus(shortcut: item.0, isRegistered: false, errorCode: status))
                AppLogger.log("shortcut unavailable \(item.0.displayString) status=\(status)")
            }
        }
    }

    func unregister() {
        registeredHotKeys.forEach { UnregisterEventHotKey($0) }
        registeredHotKeys.removeAll()
        handlers.removeAll()
        statuses.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            guard hotKeyID.signature == OSType(0x53434E50), let handler = manager.handlers[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            handler()
            return noErr
        }, 1, &eventType, selfPointer, &eventHandler)
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    deinit {
        unregister()
    }
}

extension ShortcutManager.RegistrationStatus: Equatable {
    static func == (lhs: ShortcutManager.RegistrationStatus, rhs: ShortcutManager.RegistrationStatus) -> Bool {
        lhs.shortcut == rhs.shortcut && lhs.isRegistered == rhs.isRegistered && lhs.errorCode == rhs.errorCode
    }
}

extension ShortcutManager {
    func status(for shortcut: Shortcut) -> RegistrationStatus? {
        statuses.first { $0.shortcut == shortcut }
    }

    func displayString(for shortcut: Shortcut) -> String {
        guard let status = status(for: shortcut) else {
            return shortcut.displayString + (shortcut.hasCommonAppShortcutConflict ? "（常用快捷键冲突）" : "")
        }
        return shortcut.displayString + status.displaySuffix
    }
}

private extension Shortcut {
    var hasCommonAppShortcutConflict: Bool {
        modifierFlags == [.command, .shift] && keyCode == 13
    }
}
