import AppKit
import XCTest
@testable import 截图Free

final class LongScreenshotMatchingTests: XCTestCase {
    private let service = LongScreenshotService(screenshotService: SystemScreenshotService())

    func testLoggedBuild8DimensionsPassTwentySecondFrameWithExactPixels() throws {
        var plan = LongScreenshotService.StitchPlan()
        let started = Date()
        for index in 0..<24 {
            try autoreleasepool {
                plan = try service.merging(frame: frame(width: 1791, height: 1663, offset: index * 120), into: plan)
            }
        }
        XCTAssertEqual(plan.frames.count, 24)
        XCTAssertEqual(plan.diskBytes, 24 * 1791 * 1663 * 4)
        let output = try service.stitch(plan: plan)
        XCTAssertTrue(service.imagesAreIdentical(try XCTUnwrap(output.cgImage(forProposedRect: nil, context: nil, hints: nil)),
            try frame(width: 1791, height: 4423, offset: 0)))
        print("BUILD8_SIZE frames=24 size=1791x1663 outputHeight=4423 diskBytes=\(plan.diskBytes) seconds=\(Date().timeIntervalSince(started)) pixelsEqual=true")
    }

    func testDiskPlanGrowthRollbackCleanupAndOutputBoundary() throws {
        var plan = LongScreenshotService.StitchPlan()
        let started = Date()
        for index in 0..<90 {
            plan = try service.merging(frame: frame(width: 80, height: 160, offset: index * 20), into: plan)
        }
        XCTAssertEqual(plan.frames.count, 90)
        XCTAssertEqual(plan.diskBytes, 90 * 80 * 160 * 4)
        let urls = plan.frames.map(\.url)
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let snapshot = plan
        let rollback = try service.merging(frame: frame(width: 80, height: 160, offset: 810), into: plan)
        XCTAssertEqual(rollback.frames.count, 90)
        let output = try service.stitch(plan: plan)
        XCTAssertTrue(service.imagesAreIdentical(try XCTUnwrap(output.cgImage(forProposedRect: nil, context: nil, hints: nil)),
            try frame(width: 80, height: 1940, offset: 0)))
        let limited = LongScreenshotService(screenshotService: SystemScreenshotService(), byteLimit: 17 * 1024 * 1024)
        XCTAssertThrowsError(try limited.validatePlanBudget(plan))
        XCTAssertEqual(snapshot.frames.count, 90)
        print("DISK_PLAN frames=90 residentStoredImages=0 diskBytes=\(plan.diskBytes) seconds=\(Date().timeIntervalSince(started)) pixelsEqual=true")
        var stored: StoredCaptureFrame? = try StoredCaptureFrame(frame(offset: 0))
        let url = stored!.url
        stored = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let damaged = try StoredCaptureFrame(frame(offset: 0))
        try Data([1, 2]).write(to: damaged.url)
        XCTAssertThrowsError(try damaged.load())
    }

    // 直接构造顶向下 RGBA，避免测试和生产同时使用绘图坐标而掩盖翻转错误。
    private func frame(width: Int = 240, height: Int = 400, offset: Int,
                       header: Int = 0, footer: Int = 0, dynamic: Bool = false,
                       noise: Bool = false, repeated: Bool = false, anchor: Bool = true) throws -> CGImage {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let documentY = y + offset
                var row = repeated ? documentY % 32 : documentY
                if repeated && anchor && (170..<182).contains(documentY) { row = documentY + 901 }
                for c in 0..<3 {
                    let seed = UInt64(row * 3 + c + 1) &* 0x9E3779B97F4A7C15
                    let hash = (seed ^ (seed >> 29)) &* 0xBF58476D1CE4E5B9
                    var v = 20 + (Int((hash ^ (hash >> 32)) % 210) + x * (3 + c * 2)) % 210
                    if y < header { v = 40 + c * 30 }
                    if y >= height - footer { v = 170 + c * 20 }
                    if dynamic && (100..<118).contains(y) && x < width / 5 { v = 240 }
                    if noise { v += (x + y + c) % 3 - 1 }
                    data[(y * width + x) * 4 + c] = UInt8(v)
                }
            }
        }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testNormalScrollVariants() throws {
        for (name, head, foot, dynamic, noise, repeated, shift) in [
            ("固定头尾", 36, 28, false, false, false, 137),
            ("动态小块", 0, 0, true, false, false, 137),
            ("Retina奇数像素", 0, 0, false, false, false, 139),
            ("重复纹理唯一锚点", 0, 0, false, false, true, 97),
            ("轻微噪声", 0, 0, false, true, false, 137)
        ] {
            let a = try frame(offset: 0, header: head, footer: foot, repeated: repeated)
            let b = try frame(offset: shift, header: head, footer: foot, dynamic: dynamic, noise: noise, repeated: repeated)
            do {
                let overlap = try service.validatedOverlap(previous: a, current: b)
                XCTAssertEqual(overlap, 400 - shift, name)
                let image = try service.stitch(frames: [a, b])
                let output = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                let expected = try frame(height: 400 + shift, offset: 0, header: head, footer: foot, repeated: repeated)
                XCTAssertEqual(output.height, expected.height, name)
                if !noise {
                    XCTAssertTrue(service.imagesAreIdentical(output, expected), "\(name)每个像素均应正确")
                } else {
                    func rgba(_ image: CGImage) throws -> [UInt8] {
                        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
                    }
                    let actualBytes = try rgba(output), expectedBytes = try rgba(expected)
                    XCTAssertTrue(zip(actualBytes, expectedBytes).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "噪声逐像素偏差不能超过输入的 ±1")
                }
            }
            catch { XCTFail("\(name)误拒: \(error)") }
        }
    }

    func testFixedChromeThreeFramesExactPixels() throws {
        let frames = try [0, 137, 274].map { try frame(offset: $0, header: 36, footer: 28) }
        let image = try service.stitch(frames: frames)
        let output = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let expected = try frame(height: 674, offset: 0, header: 36, footer: 28)
        XCTAssertTrue(service.imagesAreIdentical(output, expected), "逐像素验证：头尾各一次，中间无缺行、重复行或翻转")
    }

    func testTruePeriodicAmbiguityRejected() throws {
        XCTAssertThrowsError(try service.validatedOverlap(
            previous: frame(offset: 0, repeated: true, anchor: false),
            current: frame(offset: 97, repeated: true, anchor: false)))
    }

    func testUnrelatedFramesWithSameChromeRejected() throws {
        XCTAssertThrowsError(try service.stitch(frames: [
            frame(offset: 0, header: 36, footer: 28),
            frame(offset: 1000, header: 36, footer: 28)]))
    }

    func testVariableStepsAndDuplicatesExactPixels() throws {
        let frames = try [0, 3, 3, 140, 157, 157].map { try frame(offset: $0, header: 36, footer: 28) }
        let output = try service.stitch(frames: frames)
        let bitmap = try XCTUnwrap(output.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertTrue(service.imagesAreIdentical(bitmap, try frame(height: 557, offset: 0, header: 36, footer: 28)))
    }

    func testRealSizePerformanceAndPixels() throws {
        let a = try frame(width: 2676, height: 1344, offset: 0, header: 80, footer: 60)
        let b = try frame(width: 2676, height: 1344, offset: 469, header: 80, footer: 60)
        let start = Date()
        let output = try service.stitch(frames: [a, b])
        let elapsed = Date().timeIntervalSince(start)
        print("MATCH_PERF 2676x1344 two frames stitch seconds=\(elapsed)")
        XCTAssertLessThan(elapsed, 10)
        let bitmap = try XCTUnwrap(output.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertTrue(service.imagesAreIdentical(bitmap, try frame(width: 2676, height: 1813, offset: 0, header: 80, footer: 60)))
    }

    func testLoggedLargeFramesBudgetDoesNotStopAtFifthFrame() throws {
        let image = try frame(width: 3847, height: 2101, offset: 0)
        // 最新现场日志：第五帧匹配成功，却因粗略四倍预算被拒绝。
        XCTAssertThrowsError(try LongScreenshotService(screenshotService: SystemScreenshotService(),
            byteLimit: 300 * 1024 * 1024).validateBudget(frames: Array(repeating: image, count: 5)))
        XCTAssertNoThrow(try service.validateBudget(frames: Array(repeating: image, count: 5)))
        XCTAssertThrowsError(try service.validateBudget(frames: Array(repeating: image, count: 9)))
    }

    func testPlanBidirectionalRollbackAndRejectedUpdatesPreservePixels() throws {
        var plan = LongScreenshotService.StitchPlan()
        for offset in [137, 274, 0] {
            plan = try service.merging(frame: frame(offset: offset, header: 36, footer: 28), into: plan)
        }
        let calls = service.matchInvocationCount
        _ = try service.stitch(plan: plan, maximumPreviewDimension: 180)
        let output = try service.stitch(plan: plan)
        XCTAssertEqual(service.matchInvocationCount, calls, "预览及导出不再调用匹配器")
        let bitmap = try XCTUnwrap(output.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertTrue(service.imagesAreIdentical(bitmap, try frame(height: 674, offset: 0, header: 36, footer: 28)))
        for offset in [137, 65] {
            let unchanged = try service.merging(frame: frame(offset: offset, header: 36, footer: 28), into: plan)
            XCTAssertEqual(unchanged.frames.count, 3)
            XCTAssertTrue(zip(unchanged.frames, plan.frames).allSatisfy { $0 === $1 })
        }
        XCTAssertThrowsError(try service.merging(frame: frame(width: 241, offset: 400), into: plan))
        XCTAssertThrowsError(try service.merging(frame: frame(offset: 2000), into: plan))
        let limited = LongScreenshotService(screenshotService: SystemScreenshotService(), byteLimit: 1)
        XCTAssertThrowsError(try limited.stitch(plan: plan))
        XCTAssertThrowsError(try limited.merging(frame: frame(offset: 411, header: 36, footer: 28), into: plan))
        XCTAssertEqual(plan.frames.count, 3)
        let recovered = try service.stitch(plan: plan)
        XCTAssertTrue(service.imagesAreIdentical(bitmap, try XCTUnwrap(recovered.cgImage(forProposedRect: nil, context: nil, hints: nil))))
    }

    func testPlanPerformanceAgainstLegacyHistoryRematching() throws {
        // 输入生成不计入测量；两条路径使用同一对象和同一预览尺寸。
        let inputs = try (0..<8).map { try frame(width: 960, height: 600, offset: $0 * 197, header: 40, footer: 30) }
        let legacy = LongScreenshotService(screenshotService: SystemScreenshotService())
        var frames: [CGImage] = []
        let oldStart = Date()
        for input in inputs {
            frames = try legacy.merging(frame: input, into: frames)
            _ = try legacy.stitch(frames: frames, maximumPreviewDimension: 840)
        }
        let oldImage = try legacy.stitch(frames: frames)
        let oldElapsed = Date().timeIntervalSince(oldStart)
        let incremental = LongScreenshotService(screenshotService: SystemScreenshotService())
        var plan = LongScreenshotService.StitchPlan()
        let newStart = Date()
        for input in inputs {
            let before = incremental.matchInvocationCount
            plan = try incremental.merging(frame: input, into: plan)
            XCTAssertEqual(incremental.matchInvocationCount - before, plan.frames.count == 1 ? 0 : 2,
                           "单向扩展只检查新帧与两个边界，不重新匹配历史边")
            let afterMerge = incremental.matchInvocationCount
            _ = try incremental.stitch(plan: plan, maximumPreviewDimension: 840)
            XCTAssertEqual(incremental.matchInvocationCount, afterMerge)
        }
        let beforeExport = incremental.matchInvocationCount
        let newImage = try incremental.stitch(plan: plan)
        let newElapsed = Date().timeIntervalSince(newStart)
        XCTAssertEqual(incremental.matchInvocationCount, beforeExport)
        XCTAssertEqual(legacy.matchInvocationCount, 49)
        XCTAssertEqual(incremental.matchInvocationCount, 14)
        let oldBitmap = try XCTUnwrap(oldImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let newBitmap = try XCTUnwrap(newImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertTrue(service.imagesAreIdentical(oldBitmap, newBitmap))
        XCTAssertTrue(service.imagesAreIdentical(newBitmap,
            try frame(width: 960, height: 1979, offset: 0, header: 40, footer: 30)))
        print("PLAN_PERF frames=8 size=960x600 legacySeconds=\(oldElapsed) planSeconds=\(newElapsed) legacyMatches=\(legacy.matchInvocationCount) planMatches=\(incremental.matchInvocationCount) pixelsEqual=true")
    }
}
