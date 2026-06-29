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
        self.modifierFlags = modifierFlags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let rawValue = try container.decode(UInt.self, forKey: .modifierRawValue)
        modifierFlags = NSEvent.ModifierFlags(rawValue: rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifierFlags.rawValue, forKey: .modifierRawValue)
    }

    var displayString: String {
        var parts: [String] = []
        if modifierFlags.contains(.command) { parts.append("⌘") }
        if modifierFlags.contains(.shift) { parts.append("⇧") }
        if modifierFlags.contains(.option) { parts.append("⌥") }
        if modifierFlags.contains(.control) { parts.append("⌃") }
        parts.append(keyDisplayName)
        return parts.joined()
    }

    private var keyDisplayName: String {
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
}
