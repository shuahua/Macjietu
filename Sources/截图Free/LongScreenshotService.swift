import AppKit

enum LongScreenshotError: LocalizedError {
    case accessibilityPermissionRequired
    case noFramesCaptured
    case incompatibleFrames
    case untrustedOverlap
    case memoryLimit
    case resourceLimit(LongCaptureBudget)
    case inputLimit(category: String, measured: Double, limit: Double)
    case directionChanged
    case scrollUnconfirmed

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
            return "长截图达到输出像素、工作内存或临时磁盘安全上限，请分段截取。"
        case .resourceLimit(let budget):
            return budget.message
        case .inputLimit(let category, let measured, let limit):
            return "长截图达到\(category)安全上限：计算值 \(measured)，限制 \(limit)。已停止追加，将尝试恢复已确认内容。"
        case .directionChanged:
            return "请保持同一方向滚动；反向滚动可能重复已有内容，请重新截取。"
        case .scrollUnconfirmed:
            return "页面没有变化，无法确认滚动生效或已经到底。请检查目标位置，或使用手动模式。"
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
    private let metricsLock = NSLock()
    private var matchCalls = 0
    var matchInvocationCount: Int {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return matchCalls
    }

    // 值类型快照：仅由服务构造，帧与已验证边始终一起交付，不跨会话缓存。
    struct StitchPlan {
        fileprivate(set) var frames: [StoredCaptureFrame] = []
        fileprivate var edges: [Match] = []
        var diskBytes: Int { frames.reduce(0) { $0 + $1.byteCount } }
    }

    func merging(frame: CGImage, into plan: StitchPlan) throws -> StitchPlan {
        guard let firstRecord = plan.frames.first, let lastRecord = plan.frames.last else {
            try validateBudget(frames: [frame])
            let initial = StitchPlan(frames: [try StoredCaptureFrame(frame)])
            try validatePlanBudget(initial)
            return initial
        }
        let first = try firstRecord.load(), last = try lastRecord.load()
        guard frame.width == first.width, frame.height == first.height else {
            throw LongScreenshotError.incompatibleFrames
        }
        try validateBudget(frames: [last, frame])
        if try hasNoNewContent(last, frame) || imagesAreIdentical(first, frame) {
            AppLogger.log("long tail verified zero displacement; retained=\(plan.frames.count)")
            return plan
        }
        let down = try optionalMatch(previous: last, current: frame)
        let up = try optionalMatch(previous: frame, current: first)
        guard down == nil || up == nil else { throw LongScreenshotError.untrustedOverlap }
        var next = plan
        if let down {
            try validateCandidate(plan, match: down)
            next.frames.append(try StoredCaptureFrame(frame))
            next.edges.append(down)
        } else if let up {
            try validateCandidate(plan, match: up)
            next.frames.insert(try StoredCaptureFrame(frame), at: 0)
            next.edges.insert(up, at: 0)
        } else {
            for index in plan.frames.indices.dropFirst() {
                let covered = try autoreleasepool {
                    let previous = try plan.frames[index - 1].load()
                    let current = try plan.frames[index].load()
                    if imagesAreIdentical(current, frame) { return true }
                    if let left = try optionalMatch(previous: previous, current: frame),
                       let right = try optionalMatch(previous: frame, current: current),
                       left.shift + right.shift == plan.edges[index - 1].shift { return true }
                    return false
                }
                if covered { return plan }
            }
            throw LongScreenshotError.untrustedOverlap
        }
        try validatePlanBudget(next)
        // 接缝发生交叉时拒绝更新，原快照仍可用于恢复。
        _ = try slices(for: next)
        return next
    }

    private func slices(for plan: StitchPlan) throws -> (starts: [Int], ends: [Int]) {
        guard let first = plan.frames.first else { throw LongScreenshotError.noFramesCaptured }
        guard plan.edges.count == plan.frames.count - 1 else { throw LongScreenshotError.untrustedOverlap }
        var starts = [Int](repeating: 0, count: plan.frames.count)
        var ends = [Int](repeating: first.height, count: plan.frames.count)
        for index in plan.frames.indices.dropFirst() {
            let match = plan.edges[index - 1]
            if match.shift == 0 {
                starts[index] = first.height
            } else {
                var previousIndex = index - 1
                while previousIndex > 0 && starts[previousIndex] == ends[previousIndex] { previousIndex -= 1 }
                ends[previousIndex] = match.shift + match.seam
                starts[index] = match.seam
            }
        }
        guard zip(starts, ends).allSatisfy({ 0 <= $0 && $0 <= $1 && $1 <= first.height }) else {
            throw LongScreenshotError.untrustedOverlap
        }
        return (starts, ends)
    }

    static func scrollStep(height: CGFloat) -> Int32 {
        guard height.isFinite, height > 0 else { return 1 }
        return Int32(min(120, max(1, floor(height * 0.15))))
    }

    private func validateCandidate(_ plan: StitchPlan, match: Match) throws {
        guard let first = plan.frames.first else { return }
        let (starts, ends) = try slices(for: plan)
        let height = zip(starts, ends).reduce(0) { $0 + $1.1 - $1.0 } + match.shift
        try LongCaptureBudget(frames: plan.frames.count + 1, width: first.width,
            frameHeight: first.height, outputHeight: height,
            diskBytes: plan.diskBytes + first.byteCount, memoryLimit: byteLimit).validate(stage: "candidate")
    }

    func validatePlanBudget(_ plan: StitchPlan, stage: String = "plan") throws {
        guard let first = plan.frames.first else { return }
        let (starts, ends) = try slices(for: plan)
        let height = zip(starts, ends).reduce(0) { $0 + $1.1 - $1.0 }
        try LongCaptureBudget(frames: plan.frames.count, width: first.width,
            frameHeight: first.height, outputHeight: height, diskBytes: plan.diskBytes,
            memoryLimit: byteLimit).validate(stage: stage)
    }

    // 独立选区输入 + 最坏输出/绘制空间(2倍输入) + 两张解码工作帧。
    func validateBudget(frames: [CGImage]) throws {
        func reject(_ category: String, _ value: Double, _ limit: Double) throws {
            AppLogger.log("long input budget rejected category=\(category) measured=\(value) limit=\(limit) frames=\(frames.count)")
            throw LongScreenshotError.inputLimit(category: category, measured: value, limit: limit)
        }
        guard frames.count <= 80 else { return try reject("内存输入帧数", Double(frames.count), 80) }
        var bytes = 0.0
        var largest = 0.0
        for frame in frames {
            let cost = max(Double(frame.bytesPerRow), Double(frame.width) * 4) * Double(frame.height)
            bytes += cost
            largest = max(largest, cost)
        }
        let peak = 2 * (bytes + largest)
        if peak > Double(byteLimit) { try reject("内存输入工作字节", peak, Double(byteLimit)) }
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

        var plan = StitchPlan()
        var frames: [StoredCaptureFrame] { plan.frames }
        var sameFrameCount = 0
        var retries = 0
        var needsScroll = true
        let maxFrames = 20
        let scrollDelta = Self.scrollStep(height: rect.height)

        while frames.count < maxFrames {
            try Task.checkCancellation()
            let image = try await screenshotService.captureRegion(rect: rect)
            guard let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw LongScreenshotError.noFramesCaptured
            }
            let isDuplicateFrame = try frames.last.map { imagesAreIdentical(try $0.load(), frame) } ?? false
            if isDuplicateFrame {
                sameFrameCount += 1
            } else {
                sameFrameCount = 0
            }

            if !isDuplicateFrame {
                var next = plan
                if let previous = frames.last {
                    do { next.edges.append(try matchFrames(previous: previous.load(), current: frame)) }
                    catch LongScreenshotError.untrustedOverlap {
                        retries += 1
                        guard retries < 6 else { throw LongScreenshotError.untrustedOverlap }
                        try await Task.sleep(nanoseconds: 450_000_000)
                        continue
                    }
                }
                retries = 0
                needsScroll = true
                next.frames.append(try StoredCaptureFrame(frame))
                try validatePlanBudget(next)
                _ = try slices(for: next)
                plan = next
                await progress(frames.count)
            }

            if sameFrameCount >= 8 { throw LongScreenshotError.scrollUnconfirmed }

            if frames.count >= maxFrames { break }
            if needsScroll { scrollDown(delta: scrollDelta, at: rect.center); needsScroll = false }
            try await Task.sleep(nanoseconds: 520_000_000)
        }

        let image = try stitch(plan: plan)
        return LongScreenshotResult(image: image, frameCount: frames.count, stopReason: .maxFrames)
    }

    // 事件方向不能决定图片顺序。双向验证位置；回滚到已覆盖区域不扩图。
    func merging(frame: CGImage, into frames: [CGImage]) throws -> [CGImage] {
        guard let first = frames.first, let last = frames.last else {
            try validateBudget(frames: [frame]); return [frame]
        }
        if frames.contains(where: { imagesAreIdentical($0, frame) }) { return frames }
        let down = try? matchFrames(previous: last, current: frame)
        let up = try? matchFrames(previous: frame, current: first)
        guard down == nil || up == nil else { throw LongScreenshotError.untrustedOverlap }
        if down != nil { try validateBudget(frames: frames + [frame]); return frames + [frame] }
        if up != nil { try validateBudget(frames: [frame] + frames); return [frame] + frames }
        // 判断是否处于某个已覆盖区间，不因事件符号变化盲目拒绝或倒序。
        for index in frames.indices.dropFirst() {
            if let left = try? matchFrames(previous: frames[index - 1], current: frame),
               let right = try? matchFrames(previous: frame, current: frames[index]),
               let span = try? matchFrames(previous: frames[index - 1], current: frames[index]),
               left.shift + right.shift == span.shift { return frames }
        }
        throw LongScreenshotError.untrustedOverlap
    }

    func stitch(frames: [CGImage], maximumPreviewDimension: Int? = nil) throws -> NSImage {
        try validateBudget(frames: frames)
        var plan = StitchPlan(frames: try frames.map { try StoredCaptureFrame($0) })
        for index in frames.indices.dropFirst() {
            plan.edges.append(try matchFrames(previous: frames[index - 1], current: frames[index]))
        }
        return try stitch(plan: plan, maximumPreviewDimension: maximumPreviewDimension)
    }

    func stitch(plan: StitchPlan, maximumPreviewDimension: Int? = nil) throws -> NSImage {
        let frames = plan.frames
        guard let first = frames.first else { throw LongScreenshotError.noFramesCaptured }
        try validatePlanBudget(plan, stage: maximumPreviewDimension == nil ? "final" : "preview")
        guard frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw LongScreenshotError.incompatibleFrames
        }
        let width = first.width
        if frames.count == 1, maximumPreviewDimension == nil {
            return NSImage(cgImage: try first.load(), size: CGSize(width: first.width, height: first.height))
        }
        let (starts, ends) = try slices(for: plan)
        let height = zip(starts, ends).reduce(0) { $0 + $1.1 - $1.0 }
        let scale = maximumPreviewDimension.map { min(1, Double(max(1, $0)) / Double(max(width, height))) } ?? 1
        let outputWidth = max(1, Int((Double(width) * scale).rounded()))
        let outputHeight = max(1, Int((Double(height) * scale).rounded()))
        AppLogger.log("long render frames=\(frames.count) source=\(width)x\(height) allocation=\(outputWidth)x\(outputHeight) preview=\(maximumPreviewDimension != nil)")

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw LongScreenshotError.noFramesCaptured
        }

        context.scaleBy(x: CGFloat(outputWidth) / CGFloat(width), y: CGFloat(outputHeight) / CGFloat(height))
        var y = height
        for (index, record) in frames.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
            let frame = try record.load()
            let croppedOverlap = starts[index]
            let drawHeight = ends[index] - starts[index]
            // 完全重复的帧不贡献新像素，也不能用零高度区域 cropping。
            if drawHeight == 0 { return }
            y -= drawHeight
            let sourceRect = CGRect(x: 0, y: croppedOverlap, width: frame.width, height: drawHeight)
            guard let croppedFrame = frame.cropping(to: sourceRect) else { throw LongScreenshotError.noFramesCaptured }
            context.draw(croppedFrame, in: CGRect(x: 0, y: y, width: width, height: drawHeight))
            }
        }

        guard let cgImage = context.makeImage() else {
            throw LongScreenshotError.noFramesCaptured
        }
        return NSImage(cgImage: cgImage, size: CGSize(width: outputWidth, height: outputHeight))
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
        current.height - (try matchFrames(previous: previous, current: current)).shift
    }

    fileprivate struct Match {
        let shift: Int
        let seam: Int
    }

    private func optionalMatch(previous: CGImage, current: CGImage) throws -> Match? {
        do { return try matchFrames(previous: previous, current: current) }
        catch LongScreenshotError.untrustedOverlap { return nil }
    }

    private func matchFrames(previous: CGImage, current: CGImage) throws -> Match {
        try Task.checkCancellation()
        metricsLock.lock()
        matchCalls += 1
        metricsLock.unlock()
        guard previous.width == current.width, previous.height == current.height else {
            throw LongScreenshotError.incompatibleFrames
        }
        try validateBudget(frames: [previous, current])
        // 手动模式可能在没有滚动时重复捕获。仅跳过逐像素相同帧，
        // 不使用缩略图阈值，以免吞掉稀疏文字中的细微滚动。
        if imagesAreIdentical(previous, current) { return Match(shift: 0, seam: 0) }
        let height = current.height
        let columns = min(48, current.width)
        // 仅横向采样，保留每一条原始像素行；一次解码，禁止每个位移重新裁图/缩放。
        guard let a = rowSamples(previous, columns: columns),
              let b = rowSamples(current, columns: columns) else { throw LongScreenshotError.noFramesCaptured }
        func difference(_ ay: Int, _ by: Int) -> Double {
            var sum = 0
            for x in 0..<columns {
                let ai = (ay * columns + x) * 3, bi = (by * columns + x) * 3
                let delta = abs(Int(a[ai]) - Int(b[bi])) + abs(Int(a[ai + 1]) - Int(b[bi + 1])) + abs(Int(a[ai + 2]) - Int(b[bi + 2]))
                // 有界损失限制局部动画影响，但不丢掉独特锚点所在的整条横带。
                sum += min(24, delta)
            }
            return Double(sum) / Double(columns)
        }
        var top = 0, bottom = height
        while top < height && difference(top, top) <= 3 { top += 1 }
        while bottom > top && difference(bottom - 1, bottom - 1) <= 3 { bottom -= 1 }
        let minimum = max(24, height / 5)
        guard bottom - top > minimum else {
            AppLogger.log("long match rejected stationary/insufficient content size=\(current.width)x\(height) stable=\(top)..<\(bottom)")
            throw LongScreenshotError.untrustedOverlap
        }
        var candidates: [(shift: Int, score: Double)] = []
        for shift in 1...(bottom - top - minimum) {
            // 粗筛只淘汰明显错误的位移；所有近似/周期候选都进入逐行复核，
            // 不使用 top-K，否则未采到唯一锚点时会丢掉正确候选。
            var coarse = 0.0, count = 0
            for row in stride(from: top, to: bottom - shift, by: 8) {
                coarse += difference(row + shift, row)
                count += 1
            }
            if coarse > Double(count) * 10 { continue }
            var total = 0.0
            for row in top..<(bottom - shift) { total += difference(row + shift, row) }
            candidates.append((shift, total / Double(bottom - shift - top)))
        }
        candidates.sort { $0.score < $1.score }
        guard let best = candidates.first else { throw LongScreenshotError.untrustedOverlap }
        let runner = candidates.dropFirst().first?.score ?? .infinity
        guard best.score <= 6, runner > best.score + 0.25 else {
            AppLogger.log("long match rejected size=\(current.width)x\(height) stable=\(top)..<\(bottom) shift=\(best.shift) score=\(best.score) runner=\(runner)")
            throw LongScreenshotError.untrustedOverlap
        }
        // 接缝两侧必须连续通过，避免局部动画正好落在裁剪边界。
        let range = top..<(bottom - best.shift)
        let middle = (range.lowerBound + range.upperBound) / 2
        let seams = range.dropFirst(2).dropLast(2).filter { row in
            (row - 2...row + 2).allSatisfy { difference($0 + best.shift, $0) <= 6 }
        }
        guard let seam = seams.min(by: { abs($0 - middle) < abs($1 - middle) }) else { throw LongScreenshotError.untrustedOverlap }
        AppLogger.log("long match accepted size=\(current.width)x\(height) stable=\(top)..<\(bottom) shift=\(best.shift) score=\(best.score) runner=\(runner) seam=\(seam)")
        return Match(shift: best.shift, seam: seam)
    }

    private func rowSamples(_ image: CGImage, columns: Int) -> [UInt8]? {
        guard let pixels = downsample(image, width: image.width, height: image.height) else { return nil }
        var result = [UInt8]()
        result.reserveCapacity(image.height * columns * 3)
        for y in 0..<image.height {
            for x in 0..<columns {
                let sourceX = min(image.width - 1, (2 * x + 1) * image.width / (2 * columns))
                let i = (y * image.width + sourceX) * 4
                result.append(contentsOf: pixels[i..<i + 3])
            }
        }
        return result
    }

    // 全分辨率逐通道验证零位移；不以“静态采样带”或全图平均值推断无新增。
    // 仅容忍 8-bit 渲染舍入噪声，任何像素的实质变化仍走重叠验证/缺口路径。
    func hasNoNewContent(_ lhs: CGImage, _ rhs: CGImage) throws -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return false }
        try validateBudget(frames: [lhs, rhs])
        guard let left = downsample(lhs, width: lhs.width, height: lhs.height),
              let right = downsample(rhs, width: rhs.width, height: rhs.height) else {
            throw LongScreenshotError.noFramesCaptured
        }
        return zip(left, right).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
    }

    func imagesAreIdentical(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return false }
        if lhs === rhs { return true }
        guard (try? validateBudget(frames: [lhs, rhs])) != nil else { return false }
        guard let left = downsample(lhs, width: lhs.width, height: lhs.height),
              let right = downsample(rhs, width: rhs.width, height: rhs.height) else { return false }
        return left == right
    }

}
