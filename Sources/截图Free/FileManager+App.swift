import Foundation

extension FileManager {
    var applicationSupportDirectory: URL {
        urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}
