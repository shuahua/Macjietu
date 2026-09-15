import AppKit
import XCTest
@testable import 截图Free

final class LongCaptureBudgetTests: XCTestCase {
    private func budget(height: Int = 8784, count: Int = 29, disk: Int = 918601448,
                        limit: Int = 512 * 1024 * 1024) -> LongCaptureBudget {
        LongCaptureBudget(frames: count, width: 3833, frameHeight: 2066,
                          outputHeight: height, diskBytes: disk, memoryLimit: limit)
    }

    func testObservedBuild9RejectionWasSumOfDisjointPhases() throws {
        let old = 2 * 3833 * 8784 * 4 + 8 * 3833 * 2066 * 4 + 16 * 1024 * 1024
        XCTAssertGreaterThan(old, 512 * 1024 * 1024)
        let b = budget()
        XCTAssertEqual(b.category, "accepted")
        XCTAssertEqual(b.peakBytes, max(b.matchingBytes, b.renderingBytes))
        try b.validate(stage: "regression")
        print("预算复现 old=\(old) new=\(b.peakBytes) limit=\(b.memoryLimit)")
    }

    func testExactMemoryBoundaryAndEachIndependentProtection() throws {
        let b = budget()
        XCTAssertEqual(budget(limit: Int(b.peakBytes)).category, "accepted")
        XCTAssertEqual(budget(limit: Int(b.peakBytes) - 1).category, "working_memory_bytes")
        XCTAssertEqual(budget(count: 4097).category, "frame_count")
        XCTAssertEqual(budget(disk: 2 * 1024 * 1024 * 1024).category, "accepted")
        XCTAssertEqual(budget(disk: 2 * 1024 * 1024 * 1024 + 1).category, "temporary_disk_bytes")
        XCTAssertEqual(budget(height: 100001).category, "output_height")
        XCTAssertEqual(budget(height: 15654).category, "output_pixels")
        let rejected = budget(limit: Int(b.peakBytes) - 1)
        XCTAssertThrowsError(try rejected.validate(stage: "boundary")) { error in
            XCTAssertTrue(error.localizedDescription.contains(String(Int(b.peakBytes))))
            XCTAssertTrue(error.localizedDescription.contains("工作内存"))
        }
    }

    func testHistoryOnlyChangesDiskNotResidentMemory() {
        XCTAssertEqual(budget().peakBytes, budget(count: 60, disk: 1900554720).peakBytes)
    }

    func testActualDimensions29FramesPreviewFinalAndRejectedAppendRecovery() throws {
        let width = 3833, height = 8784, frameHeight = 2066
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // 确定性独特行，非用户图像。随机行避免周期列表歧义。
        var seed: UInt64 = 12345
        for row in 0..<height {
            seed = seed &* 6364136223846793005 &+ 1
            context.setFillColor(CGColor(red: CGFloat((seed >> 24) & 255) / 255,
                green: CGFloat((seed >> 32) & 255) / 255, blue: CGFloat((seed >> 40) & 255) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }
        let source = try XCTUnwrap(context.makeImage())
        let service = LongScreenshotService(screenshotService: SystemScreenshotService())
        var plan = LongScreenshotService.StitchPlan()
        for index in 0..<29 {
            let offset = index == 0 ? 0 : index * 240 - 2
            try autoreleasepool {
                let frame = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: offset, width: width, height: frameHeight)))
                plan = try service.merging(frame: frame, into: plan)
            }
        }
        XCTAssertEqual(plan.frames.count, 29)
        XCTAssertEqual(plan.diskBytes, 918601448)
        let preview = try service.stitch(plan: plan, maximumPreviewDimension: 840)
        XCTAssertEqual(preview.size, CGSize(width: 367, height: 840))
        let output = try XCTUnwrap(service.stitch(plan: plan).cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(output.width, width); XCTAssertEqual(output.height, height)
        // 逐行采样比较原始源与输出，避免测试自身同时复制两张巨幅 RGBA。
        let expected = try XCTUnwrap(source.dataProvider?.data)
        let actual = try XCTUnwrap(output.dataProvider?.data)
        let a = CFDataGetBytePtr(expected)!, b = CFDataGetBytePtr(actual)!
        for row in 0..<height {
            for channel in 0..<4 { XCTAssertEqual(a[row * source.bytesPerRow + channel], b[row * output.bytesPerRow + channel]) }
        }
        let constrained = LongScreenshotService(screenshotService: SystemScreenshotService(), byteLimit: Int(budget().peakBytes) - 1)
        XCTAssertThrowsError(try constrained.validatePlanBudget(plan))
        XCTAssertEqual(plan.frames.count, 29)
        XCTAssertNoThrow(try service.stitch(plan: plan, maximumPreviewDimension: 840))
        print("实际尺寸回归 frames=29 disk=\(plan.diskBytes) final=\(output.width)x\(output.height) preview=\(preview.size)")
    }
}
