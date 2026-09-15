import Foundation

enum SmoothScroll {
    static func segments(delta: Int32) -> [Int32] {
        let count = max(1, Int((abs(Int64(delta)) + 5) / 6))
        return (0..<count).map { index in
            Int32(Int64(delta) * Int64(index + 1) / Int64(count) - Int64(delta) * Int64(index) / Int64(count))
        }
    }

    @MainActor
    static func run(delta: Int32, post: (Int32) throws -> Void) async throws {
        for segment in segments(delta: delta) {
            try Task.checkCancellation()
            try post(segment)
            try await Task.sleep(nanoseconds: 16_000_000)
        }
    }
}
