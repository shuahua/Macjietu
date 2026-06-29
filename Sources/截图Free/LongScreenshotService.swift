import AppKit

enum LongScreenshotError: LocalizedError {
    case accessibilityPermissionRequired
    case noFramesCaptured

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "长截图需要辅助功能权限，用于自动滚动页面。"
        case .noFramesCaptured:
            return "未能捕获长截图内容。"
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

    init(screenshotService: SystemScreenshotService) {
        self.screenshotService = screenshotService
    }

    func captureAutomatically(
        rect: CGRect,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> LongScreenshotResult {
        guard AccessibilityPermissionChecker.isTrusted else {
            throw LongScreenshotError.accessibilityPermissionRequired
        }

        var frames: [CGImage] = []
        var sameFrameCount = 0
        let maxFrames = 20
        let scrollDelta = max(120, Int32(rect.height * 0.72))

        while frames.count < maxFrames {
            try Task.checkCancellation()
            let image = try await screenshotService.captureRegion(rect: rect)
            guard let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw LongScreenshotError.noFramesCaptured
            }
            let isDuplicateFrame = frames.last.map { isMostlySame($0, frame) } ?? false
            if isDuplicateFrame {
                sameFrameCount += 1
            } else {
                sameFrameCount = 0
            }

            if !isDuplicateFrame || sameFrameCount < 2 {
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
        let width = first.width
        var overlaps: [Int] = []
        for index in 1..<frames.count {
            overlaps.append(bestOverlap(previous: frames[index - 1], current: frames[index]))
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
            return NSImage(size: CGSize(width: width, height: height))
        }

        var y = height
        for (index, frame) in frames.enumerated() {
            let croppedOverlap = index == 0 ? 0 : overlaps[index - 1]
            let drawHeight = frame.height - croppedOverlap
            y -= drawHeight
            let sourceRect = CGRect(x: 0, y: croppedOverlap, width: frame.width, height: drawHeight)
            guard let croppedFrame = frame.cropping(to: sourceRect) else { continue }
            context.draw(croppedFrame, in: CGRect(x: 0, y: y, width: width, height: drawHeight))
        }

        guard let cgImage = context.makeImage() else {
            return NSImage(size: CGSize(width: width, height: height))
        }
        return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
    }

    private func scrollDown(delta: Int32, at point: CGPoint) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0) else {
            return
        }
        event.location = CGPoint(x: point.x, y: quartzY(for: point))
        event.post(tap: .cghidEventTap)
    }

    private func quartzY(for point: CGPoint) -> CGFloat {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            return point.y
        }
        return screen.frame.maxY - point.y + screen.frame.minY
    }

    func isMostlySame(_ lhs: CGImage, _ rhs: CGImage, threshold: Double = 0.012) -> Bool {
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

    private func bestOverlap(previous: CGImage, current: CGImage) -> Int {
        let maxOverlap = min(previous.height, current.height) - 1
        let minOverlap = min(maxOverlap, max(4, Int(Double(previous.height) * 0.015)))
        guard maxOverlap > minOverlap else { return min(previous.height, current.height) / 4 }

        var best = maxOverlap
        var bestScore = Double.greatestFiniteMagnitude
        let sampleWidth = min(96, previous.width, current.width)
        let sampleHeight = 24
        let coarseStep = max(1, (maxOverlap - minOverlap) / 80)

        searchOverlap(
            previous: previous,
            current: current,
            minOverlap: minOverlap,
            maxOverlap: maxOverlap,
            step: coarseStep,
            sampleWidth: sampleWidth,
            sampleHeight: sampleHeight,
            best: &best,
            bestScore: &bestScore
        )

        let fineMin = max(minOverlap, best - coarseStep * 2)
        let fineMax = min(maxOverlap, best + coarseStep * 2)
        searchOverlap(
            previous: previous,
            current: current,
            minOverlap: fineMin,
            maxOverlap: fineMax,
            step: 1,
            sampleWidth: sampleWidth,
            sampleHeight: sampleHeight,
            best: &best,
            bestScore: &bestScore
        )

        if bestScore > 42 {
            AppLogger.log("long screenshot overlap fallback score=\(bestScore)")
            return 0
        }

        AppLogger.log("long screenshot best overlap=\(best) score=\(bestScore)")
        return best
    }

    private func searchOverlap(
        previous: CGImage,
        current: CGImage,
        minOverlap: Int,
        maxOverlap: Int,
        step: Int,
        sampleWidth: Int,
        sampleHeight: Int,
        best: inout Int,
        bestScore: inout Double
    ) {
        for overlap in stride(from: minOverlap, through: maxOverlap, by: step) {
            let score = overlapScore(previous: previous, current: current, overlap: overlap, sampleWidth: sampleWidth, sampleHeight: sampleHeight)
            if score < bestScore {
                bestScore = score
                best = overlap
            }
        }
    }

    private func overlapScore(previous: CGImage, current: CGImage, overlap: Int, sampleWidth: Int, sampleHeight: Int) -> Double {
        let maxOffset = max(0, overlap - sampleHeight)
        let offsets = uniqueOffsets([0, maxOffset / 2, maxOffset])
        var total = 0.0
        var count = 0

        for offset in offsets {
            let previousY = previous.height - overlap + offset
            let currentY = offset
            guard let previousStrip = stripPixels(previous, y: previousY, width: sampleWidth, height: sampleHeight),
                  let currentStrip = stripPixels(current, y: currentY, width: sampleWidth, height: sampleHeight) else {
                continue
            }
            total += normalizedPixelDifference(previousStrip, currentStrip)
            count += 1
        }

        return count == 0 ? Double.greatestFiniteMagnitude : total / Double(count)
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
