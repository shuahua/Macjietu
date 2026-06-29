import Foundation

enum RecordingAudioSource: String, CaseIterable {
    case none
    case microphone
    case system
    case both

    var title: String {
        switch self {
        case .none: "无声"
        case .microphone: "麦克风"
        case .system: "系统声音"
        case .both: "麦克风 + 系统声音"
        }
    }

    var needsMicrophone: Bool {
        self == .microphone || self == .both
    }

    var needsSystemAudio: Bool {
        self == .system || self == .both
    }
}
