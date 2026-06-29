import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum ScreenRecordingError: LocalizedError {
    case displayNotFound
    case invalidSelection
    case microphoneUnavailable
    case cannotStartWriter
    case cannotAddAudioTrack
    case notRecording

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "没有找到要录制的屏幕。"
        case .invalidSelection: "录屏区域无效，请重新框选。"
        case .microphoneUnavailable: "麦克风不可用或未授权。"
        case .cannotStartWriter: "无法启动视频写入。"
        case .cannotAddAudioTrack: "无法添加所选音频轨道。"
        case .notRecording: "当前没有正在进行的录屏。"
        }
    }
}

final class ScreenRecordingService: NSObject, @unchecked Sendable {
    private let writerQueue = DispatchQueue(label: "截图Free.ScreenRecordingWriter")
    private let outputURL: URL
    private var stream: SCStream?
    private var microphoneSession: AVCaptureSession?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var didStartSession = false
    private var isFinishing = false

    override init() {
        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("截图Free-Recording-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        super.init()
    }

    func start(rect: CGRect, audioSource: RecordingAudioSource, quality: RecordingQuality) async throws -> URL {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let screen = screenForRect(rect),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ScreenRecordingError.displayNotFound
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenRecordingError.displayNotFound
        }
        let scale = screen.backingScaleFactor
        let sourceRect = sourceRect(for: rect, in: screen)
        guard sourceRect.width >= 2, sourceRect.height >= 2 else {
            throw ScreenRecordingError.invalidSelection
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(2, evenDimension(Int((sourceRect.width * scale * quality.outputScale).rounded())))
        configuration.height = max(2, evenDimension(Int((sourceRect.height * scale * quality.outputScale).rounded())))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = audioSource.needsSystemAudio
        configuration.excludesCurrentProcessAudio = true

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.bitRate(width: configuration.width, height: configuration.height),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw ScreenRecordingError.cannotStartWriter }
        writer.add(videoInput)

        var systemAudioInput: AVAssetWriterInput?
        if audioSource.needsSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw ScreenRecordingError.cannotAddAudioTrack }
            writer.add(input)
            systemAudioInput = input
        }

        var microphoneInput: AVAssetWriterInput?
        if audioSource.needsMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw ScreenRecordingError.cannotAddAudioTrack }
            writer.add(input)
            microphoneInput = input
        }

        assetWriter = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.microphoneInput = microphoneInput
        didStartSession = false
        isFinishing = false

        do {
            guard writer.startWriting() else { throw ScreenRecordingError.cannotStartWriter }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
            if audioSource.needsSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
            }
            self.stream = stream

            if audioSource.needsMicrophone {
                microphoneSession = try makeMicrophoneSession()
                microphoneSession?.startRunning()
            }

            try await stream.startCapture()
            AppLogger.log("screen recording started rect=\(rect) screen=\(screen.frame) scale=\(scale) sourceRect=\(sourceRect) output=\(configuration.width)x\(configuration.height) audio=\(audioSource.rawValue) quality=\(quality.rawValue) url=\(outputURL.path)")
            return outputURL
        } catch {
            await cleanupFailedStart()
            throw error
        }
    }

    func stop() async throws -> URL {
        guard stream != nil || microphoneSession != nil else { throw ScreenRecordingError.notRecording }
        isFinishing = true
        try? await stream?.stopCapture()
        stream = nil
        microphoneSession?.stopRunning()
        microphoneSession = nil

        return try await withCheckedThrowingContinuation { continuation in
            writerQueue.async { [weak self] in
                guard let self, let writer = self.assetWriter else {
                    continuation.resume(throwing: ScreenRecordingError.notRecording)
                    return
                }
                self.videoInput?.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.microphoneInput?.markAsFinished()
                writer.finishWriting {
                    if let error = writer.error {
                        continuation.resume(throwing: error)
                    } else {
                        AppLogger.log("screen recording finished url=\(self.outputURL.path)")
                        continuation.resume(returning: self.outputURL)
                    }
                    self.assetWriter = nil
                    self.videoInput = nil
                    self.systemAudioInput = nil
                    self.microphoneInput = nil
                    self.didStartSession = false
                    self.isFinishing = false
                }
            }
        }
    }

    private var audioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
    }

    private func cleanupFailedStart() async {
        isFinishing = true
        try? await stream?.stopCapture()
        stream = nil
        microphoneSession?.stopRunning()
        microphoneSession = nil

        await withCheckedContinuation { continuation in
            writerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.assetWriter?.cancelWriting()
                self.assetWriter = nil
                self.videoInput = nil
                self.systemAudioInput = nil
                self.microphoneInput = nil
                self.didStartSession = false
                self.isFinishing = false
                try? FileManager.default.removeItem(at: self.outputURL)
                continuation.resume()
            }
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard !isFinishing,
              let writer = assetWriter,
              let input,
              input.isReadyForMoreMediaData,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !didStartSession {
            writer.startSession(atSourceTime: time)
            didStartSession = true
        }
        input.append(sampleBuffer)
    }

    private func makeMicrophoneSession() throws -> AVCaptureSession {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw ScreenRecordingError.microphoneUnavailable
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw ScreenRecordingError.microphoneUnavailable }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: writerQueue)
        guard session.canAddOutput(output) else { throw ScreenRecordingError.microphoneUnavailable }
        session.addOutput(output)
        return session
    }

    private func evenDimension(_ value: Int) -> Int {
        let clamped = max(2, value)
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }

    private func screenForRect(_ rect: CGRect) -> NSScreen? {
        guard let screen = NSScreen.screens.max(by: { first, second in
            intersectionArea(rect, screenFrame: first.frame) < intersectionArea(rect, screenFrame: second.frame)
        }) else { return nil }
        guard intersectionArea(rect, screenFrame: screen.frame) > 0 else {
            AppLogger.log("screen recording no screen intersection rect=\(rect) screens=\(NSScreen.screens.map(\.frame))")
            return nil
        }
        return screen
    }

    private func intersectionArea(_ rect: CGRect, screenFrame: CGRect) -> CGFloat {
        let intersection = rect.intersection(screenFrame)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func displayScale(for displayID: CGDirectDisplayID) -> CGFloat {
        guard let screen = screen(for: displayID) else { return 1 }
        return screen.backingScaleFactor
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        })
    }

    private func sourceRect(for rect: CGRect, in screen: NSScreen) -> CGRect {
        let intersection = rect.intersection(screen.frame)
        guard !intersection.isNull else { return .zero }

        let x = max(0, intersection.minX - screen.frame.minX)
        let y = max(0, screen.frame.maxY - intersection.maxY)
        let width = min(intersection.width, screen.frame.width - x)
        let height = min(intersection.height, screen.frame.height - y)
        return CGRect(x: x, y: y, width: width, height: height).integral
    }
}

extension ScreenRecordingService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard isCompleteFrame(sampleBuffer) else { return }
            append(sampleBuffer, to: videoInput)
        case .audio:
            append(sampleBuffer, to: systemAudioInput)
        case .microphone:
            append(sampleBuffer, to: microphoneInput)
        @unknown default:
            break
        }
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return false
        }
        return status == .complete
    }
}

extension ScreenRecordingService: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        append(sampleBuffer, to: microphoneInput)
    }
}
