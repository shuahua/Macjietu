import ApplicationServices
import Foundation

enum AccessibilityPermissionChecker {
    static var isTrusted: Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: false] as CFDictionary)
    }

    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func refreshStatus() -> Bool {
        isTrusted
    }
}
