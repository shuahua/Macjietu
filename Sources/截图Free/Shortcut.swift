import AppKit

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: NSEvent.ModifierFlags

    static let defaultCapture = Shortcut(
        keyCode: 1,
        modifierFlags: [.command, .shift]
    )

    static let defaultWindowCapture = Shortcut(
        keyCode: 13,
        modifierFlags: [.control, .shift]
    )

    static let defaultFullScreenCapture = Shortcut(
        keyCode: 3,
        modifierFlags: [.command, .shift]
    )

    static let defaultLongCapture = Shortcut(
        keyCode: 1,
        modifierFlags: [.control, .shift]
    )

    enum CodingKeys: String, CodingKey {
        case keyCode
        case modifierRawValue
    }

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags.intersection([.command, .option, .control, .shift])
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let rawValue = try container.decode(UInt.self, forKey: .modifierRawValue)
        modifierFlags = NSEvent.ModifierFlags(rawValue: rawValue).intersection([.command, .option, .control, .shift])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifierFlags.rawValue, forKey: .modifierRawValue)
    }

    var displayString: String {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.option) { parts.append("⌥") }
        if modifierFlags.contains(.shift) { parts.append("⇧") }
        if modifierFlags.contains(.command) { parts.append("⌘") }
        parts.append(keyDisplayName)
        return parts.joined()
    }

    /// 菜单使用 AppKit 的快捷键列；无法准确表示的物理键位由调用方显示文本。
    var menuKeyEquivalent: String? {
        if let index = Self.functionKeys.firstIndex(of: keyCode) {
            return String(UnicodeScalar(0xF704 + index)!)
        }
        let special: [UInt16: UInt32] = [36:13,48:9,49:32,51:8,53:27,117:0xF728,
            123:0xF702,124:0xF703,125:0xF701,126:0xF700,115:0xF729,119:0xF72B,
            116:0xF72C,121:0xF72D,76:3]
        if let scalar = special[keyCode] { return String(UnicodeScalar(scalar)!) }
        return keyDisplayName.count == 1 ? keyDisplayName.lowercased() : nil
    }

    private var keyDisplayName: String {
        if let name = Self.specialKeys[keyCode] { return name }
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        default: return "Key\(keyCode)"
        }
    }

    static let functionKeys: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
    static let specialKeys: [UInt16: String] = {
        var names: [UInt16: String] = [18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",24:"=",27:"-",30:"]",33:"[",39:"'",41:";",42:"\\",43:",",44:"/",47:".",50:"`",36:"↩",48:"⇥",49:"Space",51:"⌫",53:"⎋",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",115:"↖",119:"↘",116:"⇞",121:"⇟",76:"⌤",65:"小键盘 .",67:"小键盘 *",69:"小键盘 +",75:"小键盘 /",78:"小键盘 −",81:"小键盘 =",82:"小键盘 0",83:"小键盘 1",84:"小键盘 2",85:"小键盘 3",86:"小键盘 4",87:"小键盘 5",88:"小键盘 6",89:"小键盘 7",91:"小键盘 8",92:"小键盘 9"]
        for (index, code) in functionKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()

    var isValidGlobalShortcut: Bool {
        ![54,55,56,57,58,59,60,61,62,63,53].contains(keyCode) &&
        (!modifierFlags.intersection([.command, .option, .control]).isEmpty || Self.functionKeys.contains(keyCode))
    }
}

enum ShortcutAction: String, CaseIterable, Codable {
    case area, window, fullScreen, automaticLong, manualLong, recording
    var title: String {
        switch self {
        case .area: "区域截图"
        case .window: "窗口截图"
        case .fullScreen: "全屏截图"
        case .automaticLong: "长截图自动滚动"
        case .manualLong: "长截图手动滚动"
        case .recording: "录屏"
        }
    }
    var legacyDefault: Shortcut? {
        switch self {
        case .area: .defaultCapture
        case .window: .defaultWindowCapture
        case .fullScreen: .defaultFullScreenCapture
        case .automaticLong: .defaultLongCapture
        case .manualLong, .recording: nil
        }
    }
}
