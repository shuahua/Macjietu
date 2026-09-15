import Foundation

/// 链路分阶段峰值估算，不是进程 RSS。历史文件仅计磁盘，不计常驻内存。
struct LongCaptureBudget: Codable {
    let frames: Int
    let width: Int
    let frameHeight: Int
    let outputHeight: Int
    let diskBytes: Int
    let memoryLimit: Int
    let frameBytes: Double
    let outputBytes: Double
    let previewBytes: Double
    let matchingBytes: Double
    let renderingBytes: Double
    let peakBytes: Double
    let category: String
    let measured: Double
    let limit: Double

    init(frames: Int, width: Int, frameHeight: Int, outputHeight: Int, diskBytes: Int, memoryLimit: Int) {
        self.frames = frames; self.width = width; self.frameHeight = frameHeight
        self.outputHeight = outputHeight; self.diskBytes = diskBytes; self.memoryLimit = memoryLimit
        // CGContext 行对齐按 64 字节保守估算，不能只计算逻辑像素。
        frameBytes = ceil(Double(width) * 4 / 64) * 64 * Double(frameHeight)
        outputBytes = ceil(Double(width) * 4 / 64) * 64 * Double(outputHeight)
        // 新旧预览各一张，最长边 840；按正方形上界预留。
        previewBytes = 2 * 840 * 840 * 4
        let reserve = Double(16 * 1024 * 1024)
        // 匹配结束才预览/输出；八帧工作空间不能与完整输出同时收费。
        matchingBytes = 8 * frameBytes + previewBytes + reserve
        // 串行解码一帧，裁剪 backing/绘制缓存再留两帧；输出 context + makeImage。
        renderingBytes = 2 * outputBytes + 3 * frameBytes + previewBytes + reserve
        peakBytes = max(matchingBytes, renderingBytes)
        let checks: [(String, Double, Double)] = [
            ("frame_count", Double(frames), 4096),
            ("temporary_disk_bytes", Double(diskBytes), 2 * 1024 * 1024 * 1024),
            ("output_height", Double(outputHeight), 100_000),
            ("output_pixels", Double(width) * Double(outputHeight), 60_000_000),
            ("working_memory_bytes", peakBytes, Double(memoryLimit))
        ]
        let failure = checks.first { $0.1 > $0.2 }
        category = failure?.0 ?? "accepted"
        measured = failure?.1 ?? peakBytes
        limit = failure?.2 ?? Double(memoryLimit)
    }

    func validate(stage: String) throws {
        let data = try JSONEncoder().encode(self)
        AppLogger.log("long budget stage=\(stage) json=\(String(decoding: data, as: UTF8.self))")
        if category != "accepted" { throw LongScreenshotError.resourceLimit(self) }
    }

    var message: String {
        let labels = ["frame_count": "帧数", "temporary_disk_bytes": "临时磁盘字节",
                      "output_height": "输出高度（像素）", "output_pixels": "输出像素数",
                      "working_memory_bytes": "工作内存估算（字节）"]
        return "长截图达到\(labels[category] ?? category)安全上限：当前计算值 \(Int64(measured))，限制 \(Int64(limit))；\(frames) 帧，输出 \(width)×\(outputHeight)。已停止追加，将尝试保留已确认的连续长图。"
    }
}
