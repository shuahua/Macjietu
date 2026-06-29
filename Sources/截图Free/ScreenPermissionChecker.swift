import CoreGraphics

enum ScreenPermissionChecker {
    static var canRecordScreen: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestRecordScreenAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
