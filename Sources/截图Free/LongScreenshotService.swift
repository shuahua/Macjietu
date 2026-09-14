import AppKit

enum LongScreenshotError: LocalizedError {
    case accessibilityPermissionRequired
    case noFramesCaptured
    case incompatibleFrames
    case untrustedOverlap
    case memoryLimit
    case directionChanged

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "长截图需要辅助功能权限，用于自动滚动页面。"
        case .noFramesCaptured:
            return "未能捕获长截图内容。"
        case .incompatibleFrames:
            return "截图帧尺寸发生变化，请在屏幕配置稳定后重新截取。"
        case .untrustedOverlap:
            return "无法确认连续内容的重叠，已停止以避免错拼。请缩小滚动幅度，并避开固定头尾、动画或重复列表。"
        case .memoryLimit:
            return "长截图达到内存或帧数安全上限，请分段截取。"
        case .directionChanged:
            return "请保持同一方向滚动；反向滚动可能重复已有内容，请重新截取。"
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

enum LongScreenshotStopReason: Sendable {
    case reachedBottom
    case maxFrames
    case cancelled
}

enum LongScreenshotAppendDirection: Sendable {
    case up
    case down
}

struct LongScreenshotResult: Sendable {
    let image: NSImage
    let frameCount: Int
    let stopReason: LongScreenshotStopReason
}

final class LongScreenshotService {
    private let screenshotService: SystemScreenshotService
    private let byteLimit: Int

    static func scrollStep(height: CGFloat) -> Int32 {
        guard height.isFinite, height > 0 else { return 1 }
        return Int32(min(CGFloat(Int32.max), max(1, floor(height * 0.35))))
    }

    // 输入、输出位图及绘制副本预留四倍空间，不把 CGContext 分配失败当内存策略。
    func validateBudget(frames: [CGImage]) throws {
        guard frames.count <= 80 else { throw LongScreenshotError.memoryLimit }
        var bytes = 0
        for frame in frames {
            let (rgbaRow, rowOverflow) = frame.width.multipliedReportingOverflow(by: 4)
            let (cost, overflow) = max(frame.bytesPerRow, rgbaRow).multipliedReportingOverflow(by: frame.height)
            guard !rowOverflow, !overflow, cost <= byteLimit / 4 - bytes else { throw LongScreenshotError.memoryLimit }
            bytes += cost
        }
    }

    init(screenshotService: SystemScreenshotService, byteLimit: Int = 512 * 1024 * 1024) {
        self.screenshotService = screenshotService
        self.byteLimit = max(0, byteLimit)
    }

    func captureAutomatically(
        rect: CGRect,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> LongScreenshotResult {
        guard CaptureGeometry.isValid(rect), rect.height * 0.72 < CGFloat(Int32.max) else {
            throw ScreenCaptureError.failed
        }
        guard AccessibilityPermissionChecker.isTrusted else {
            throw LongScreenshotError.accessibilityPermissionRequired
        }

        var frames: [CGImage] = []
        var sameFrameCount = 0
        let maxFrames = 20
        let scrollDelta = Self.scrollStep(height: rect.height)

        while frames.count < maxFrames {
            try Task.checkCancellation()
            let image = try await screenshotService.captureRegion(rect: rect)
            guard let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw LongScreenshotError.noFramesCaptured
            }
            let isDuplicateFrame = frames.last.map { imagesAreIdentical($0, frame) } ?? false
            if isDuplicateFrame {
                sameFrameCount += 1
            } else {
                sameFrameCount = 0
            }

            if !isDuplicateFrame {
                try validateBudget(frames: frames + [frame])
                if let previous = frames.last { _ = try validatedOverlap(previous: previous, current: frame) }
                frames.append(frame)
                await progress(frames.count)
            }

            if sameFrameCount >= 2 {
                let image = try stitch(frames: frames)
                return LongScreenshotResult(image: image, frameCount: frames.count, stopReason: .reachedBottom)
            }

            if frames.count >= maxFrames { break }
            scrollDown(delta: scrollDelta, at: rect.center)
            try await Task.sleep(nanoseconds: 520_000_000)
        }

        let image = try stitch(frames: frames)
        return LongScreenshotResult(image: image, frameCount: frames.count, stopReason: .maxFrames)
    }

    func stitch(frames: [CGImage]) throws -> NSImage {
        guard let first = frames.first else { throw LongScreenshotError.noFramesCaptured }
        try validateBudget(frames: frames)
        guard frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw LongScreenshotError.incompatibleFrames
        }
        let width = first.width
        if frames.count == 1 {
            return NSImage(cgImage: first, size: CGSize(width: first.width, height: first.height))
        }
        var overlaps: [Int] = []
        for index in 1..<frames.count {
            overlaps.append(try validatedOverlap(previous: frames[index - 1], current: frames[index]))
        }

        let height = frames.enumerated().reduce(0) { total, item in
            total + item.element.height - (item.offset == 0 ? 0 : overlaps[item.offset - 1])
        }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw LongScreenshotError.noFramesCaptured
        }

        var y = height
        for (index, frame) in frames.enumerated() {
            let croppedOverlap = index == 0 ? 0 : overlaps[index - 1]
            let drawHeight = frame.height - croppedOverlap
            // 完全重复的帧不贡献新像素，也不能用零高度区域 cropping。
            if drawHeight == 0 { continue }
            y -= drawHeight
            let sourceRect = CGRect(x: 0, y: croppedOverlap, width: frame.width, height: drawHeight)
            guard let croppedFrame = frame.cropping(to: sourceRect) else { throw LongScreenshotError.noFramesCaptured }
            context.draw(croppedFrame, in: CGRect(x: 0, y: y, width: width, height: drawHeight))
        }

        guard let cgImage = context.makeImage() else {
            throw LongScreenshotError.noFramesCaptured
        }
        return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
    }

    private func scrollDown(delta: Int32, at point: CGPoint) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0) else {
            return
        }
        guard let primary = CaptureDisplay.current().first else { return }
        event.location = CaptureGeometry.quartzPoint(point, primaryFrame: primary.frame)
        event.post(tap: .cghidEventTap)
    }

    func isMostlySame(_ lhs: CGImage, _ rhs: CGImage, threshold: Double = 0.012) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return false }
        let sampleWidth = 32
        let sampleHeight = 32
        guard let left = downsample(lhs, width: sampleWidth, height: sampleHeight),
              let right = downsample(rhs, width: sampleWidth, height: sampleHeight) else {
            return false
        }

        var totalDifference = 0
        for index in stride(from: 0, to: left.count, by: 4) {
            totalDifference += abs(Int(left[index]) - Int(right[index]))
            totalDifference += abs(Int(left[index + 1]) - Int(right[index + 1]))
            totalDifference += abs(Int(left[index + 2]) - Int(right[index + 2]))
        }

        let maxDifference = sampleWidth * sampleHeight * 3 * 255
        let differenceRatio = Double(totalDifference) / Double(maxDifference)
        return differenceRatio < threshold
    }

    private func downsample(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    func validatedOverlap(previous: CGImage, current: CGImage) throws -> Int {
        guard previous.width == current.width, previous.height == current.height else {
            throw LongScreenshotError.incompatibleFrames
        }
        try validateBudget(frames: [previous, current])
        // 手动模式可能在没有滚动时重复捕获。仅跳过逐像素相同帧，
        // 不使用缩略图阈值，以免吞掉稀疏文字中的细微滚动。
        if imagesAreIdentical(previous, current) { return current.height }
        let maxOverlap = min(previous.height, current.height) - 1
        let minOverlap = max(24, previous.height / 5)
        guard maxOverlap >= minOverlap else { throw LongScreenshotError.untrustedOverlap }

        var best = maxOverlap
        var bestScore = Double.greatestFiniteMagnitude
        let sampleWidth = min(96, previous.width, current.width)
        let sampleHeight = 8
        // 按原始像素搜索每个垂直位移，避免粗步长跳过文字/细线的真实匹配谷值。
        var scores: [(overlap: Int, score: Double)] = []
        for overlap in minOverlap...maxOverlap {
            let score = overlapScore(previous: previous, current: current, overlap: overlap,
                                     sampleWidth: sampleWidth, sampleHeight: sampleHeight)
            scores.append((overlap, score))
            if score < bestScore { bestScore = score; best = overlap }
        }

        guard bestScore <= 12 else { throw LongScreenshotError.untrustedOverlap }
        // 固定头尾若参与选区，当前拼接器无法安全移除；端点必须独立通过校验。
        // 动态内容只允许出现在内部一个采样带，不能用它掩盖错误接缝。
        for offset in [0, best - sampleHeight] {
            guard let left = stripPixels(previous, y: previous.height - best + offset, width: sampleWidth, height: sampleHeight),
                  let right = stripPixels(current, y: offset, width: sampleWidth, height: sampleHeight),
                  normalizedPixelDifference(left, right) <= 12 else { throw LongScreenshotError.untrustedOverlap }
        }
        // 重复行/空白会产生多个同样好的位移；不凭搜索顺序选一个硬拼。
        for candidate in scores where abs(candidate.overlap - best) > 2 {
            if candidate.score <= bestScore + 3 { throw LongScreenshotError.untrustedOverlap }
        }

        AppLogger.log("long screenshot best overlap=\(best) score=\(bestScore)")
        return best
    }

    func imagesAreIdentical(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return false }
        if lhs === rhs { return true }
        guard (try? validateBudget(frames: [lhs, rhs])) != nil else { return false }
        guard let left = downsample(lhs, width: lhs.width, height: lhs.height),
              let right = downsample(rhs, width: rhs.width, height: rhs.height) else { return false }
        return left == right
    }

    private func overlapScore(previous: CGImage, current: CGImage, overlap: Int, sampleWidth: Int, sampleHeight: Int) -> Double {
        let maxOffset = max(0, overlap - sampleHeight)
        let offsets = uniqueOffsets([0, maxOffset / 4, maxOffset / 2, maxOffset * 3 / 4, maxOffset])
        var scores: [Double] = []

        for offset in offsets {
            let previousY = previous.height - overlap + offset
            let currentY = offset
            guard let previousStrip = stripPixels(previous, y: previousY, width: sampleWidth, height: sampleHeight),
                  let currentStrip = stripPixels(current, y: currentY, width: sampleWidth, height: sampleHeight) else {
                return Double.greatestFiniteMagnitude
            }
            scores.append(normalizedPixelDifference(previousStrip, currentStrip))
        }

        // 容忍一个局部动态区域，但不能把不一致的固定头尾当成已验证内容。
        guard scores.count >= 3 else { return Double.greatestFiniteMagnitude }
        scores.sort()
        let trusted = scores.prefix(scores.count - 1)
        return trusted.max() ?? Double.greatestFiniteMagnitude
    }

    private func uniqueOffsets(_ offsets: [Int]) -> [Int] {
        var result: [Int] = []
        for offset in offsets where !result.contains(offset) {
            result.append(offset)
        }
        return result
    }

    private func stripPixels(_ image: CGImage, y: Int, width: Int, height: Int) -> [UInt8]? {
        let clampedY = min(max(y, 0), max(0, image.height - height))
        guard let cropped = image.cropping(to: CGRect(x: 0, y: clampedY, width: image.width, height: height)) else {
            return nil
        }
        return downsample(cropped, width: width, height: height)
    }

    private func normalizedPixelDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count else { return Double.greatestFiniteMagnitude }
        var total = 0
        for index in stride(from: 0, to: lhs.count, by: 4) {
            total += abs(Int(lhs[index]) - Int(rhs[index]))
            total += abs(Int(lhs[index + 1]) - Int(rhs[index + 1]))
            total += abs(Int(lhs[index + 2]) - Int(rhs[index + 2]))
        }
        return Double(total) / Double(max(1, lhs.count / 4))
    }
}
