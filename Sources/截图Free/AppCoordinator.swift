import AppKit
import UserNotifications

private enum ScreenshotKind {
    case area
    case window
    case fullScreen
    case long
}

private enum LongCaptureMode {
    case automatic
    case manual
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T?) {
        self.value = value
    }
}

@MainActor
final class AppCoordinator: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settingsStore: SettingsStore
    private let shortcutManager = ShortcutManager()
    private let captureService = ScreenCaptureService()
    private let systemScreenshotService = SystemScreenshotService()
    private lazy var longScreenshotService = LongScreenshotService(screenshotService: systemScreenshotService)
    private var overlayController: CaptureOverlayController?
    private var longCaptureOverlayController: CaptureOverlayController?
    private var annotationEditorControllers: [AnnotationEditorController] = []
    private var settingsWindowController: SettingsWindowController?
    private var longScreenshotProgressOverlayController: LongScreenshotProgressOverlayController?
    private var recordingOverlayController: CaptureOverlayController?
    private var recordingService: ScreenRecordingService?
    private var recordingOptionsWindowController: RecordingOptionsWindowController?
    private var recordingControlWindowController: RecordingControlWindowController?
    private var recordingRegionOverlayController: RecordingRegionOverlayController?
    private var recordingPreviewWindowControllers: [RecordingPreviewWindowController] = []
    private var pinnedWindows: [PinWindowController] = []
    private var isLongCaptureRunning = false
    private var longCaptureTask: Task<Void, Never>?
    private var manualLongCaptureRect: CGRect?
    private var manualLongCaptureFrames: [CGImage] = []
    private var isManualLongCaptureCapturing = false
    private var longCaptureScrollMonitor: Any?
    private var pendingScrollCapture: DispatchWorkItem?
    private var pendingLongCaptureDirection: LongScreenshotAppendDirection = .down
    private var automaticLongCaptureTask: Task<Void, Never>?
    private var automaticLongCaptureStableFrameCount = 0
    private var longCaptureKeyMonitor: Any?
    private var longCaptureLocalKeyMonitor: Any?
    private var longCaptureMode: LongCaptureMode = .manual

    override init() {
        let supportURL = FileManager.default.applicationSupportDirectory
            .appendingPathComponent("截图Free", isDirectory: true)
        settingsStore = SettingsStore(fileURL: supportURL.appendingPathComponent("settings.json"))
        super.init()
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        logRuntimeIdentity()
        configureMenuBar()
        registerShortcut()
    }

    func stop() {
        shortcutManager.unregister()
    }

    private func configureMenuBar() {
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "截图")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "截图Free"

        let menu = NSMenu()
        menu.delegate = self
        rebuildMenu(menu)
        statusItem.menu = menu
    }

    private func logRuntimeIdentity() {
        let bundle = Bundle.main
        let bundleID = bundle.bundleIdentifier ?? "unknown"
        let bundlePath = bundle.bundleURL.path
        let executablePath = bundle.executableURL?.path ?? "unknown"
        AppLogger.log("runtime identity bundleID=\(bundleID) bundlePath=\(bundlePath) executable=\(executablePath) screenPreflight=\(ScreenPermissionChecker.canRecordScreen) accessibility=\(AccessibilityPermissionChecker.isTrusted)")
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        let canRecordScreen = ScreenPermissionChecker.canRecordScreen
        let canControlComputer = AccessibilityPermissionChecker.isTrusted
        let canRecordMicrophone = RecordingPermissionChecker.canRecordMicrophone
        menu.removeAllItems()

        let permissionItem = NSMenuItem(title: "录屏权限：\(canRecordScreen ? "已开启" : "未开启")", action: nil, keyEquivalent: "")
        permissionItem.isEnabled = false
        menu.addItem(permissionItem)

        let accessibilityItem = NSMenuItem(title: "辅助功能权限：\(canControlComputer ? "已开启" : "未开启")", action: nil, keyEquivalent: "")
        accessibilityItem.isEnabled = false
        menu.addItem(accessibilityItem)

        let microphoneItem = NSMenuItem(title: "麦克风权限：\(canRecordMicrophone ? "已开启" : "未开启")", action: nil, keyEquivalent: "")
        microphoneItem.isEnabled = false
        menu.addItem(microphoneItem)

        if !canRecordScreen {
            menu.addItem(NSMenuItem(title: "请求屏幕录制权限", action: #selector(requestScreenPermissionFromMenu), keyEquivalent: ""))
        }

        if !canControlComputer {
            menu.addItem(NSMenuItem(title: "请求辅助功能权限", action: #selector(requestAccessibilityPermissionFromMenu), keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())
        let settings = settingsStore.load()
        menu.addItem(NSMenuItem(title: "区域截图    \(shortcutManager.displayString(for: settings.captureShortcut))", action: #selector(startCaptureFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "窗口截图    \(shortcutManager.displayString(for: .defaultWindowCapture))", action: #selector(startWindowCaptureFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "全屏截图    \(shortcutManager.displayString(for: .defaultFullScreenCapture))", action: #selector(startFullScreenCaptureFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "长截图自动滚动    \(shortcutManager.displayString(for: .defaultLongCapture))", action: #selector(startAutomaticLongCaptureFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "长截图手动滚动", action: #selector(startManualLongCaptureFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "录屏", action: #selector(startRecordingFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置", action: #selector(showSettingsFromMenu), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitFromMenu), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
    }

    private func registerShortcut() {
        let settings = settingsStore.load()
        shortcutManager.register(shortcuts: [
            (settings.captureShortcut, { [weak self] in Task { @MainActor in self?.startCapture(kind: .area) } }),
            (.defaultWindowCapture, { [weak self] in Task { @MainActor in self?.startCapture(kind: .window) } }),
            (.defaultFullScreenCapture, { [weak self] in Task { @MainActor in self?.startCapture(kind: .fullScreen) } }),
            (.defaultLongCapture, { [weak self] in Task { @MainActor in self?.startLongCapture(mode: .automatic) } })
        ])
    }

    @objc private func startCaptureFromMenu() {
        startCapture(kind: .area)
    }

    @objc private func startWindowCaptureFromMenu() {
        startCapture(kind: .window)
    }

    @objc private func startFullScreenCaptureFromMenu() {
        startCapture(kind: .fullScreen)
    }

    @objc private func startAutomaticLongCaptureFromMenu() {
        startLongCapture(mode: .automatic)
    }

    @objc private func startManualLongCaptureFromMenu() {
        startLongCapture(mode: .manual)
    }

    @objc private func startRecordingFromMenu() {
        startRecordingSelection()
    }

    @objc private func requestScreenPermissionFromMenu() {
        AppLogger.log("permission menu preflight=\(ScreenPermissionChecker.canRecordScreen)")
        if ScreenPermissionChecker.canRecordScreen {
            showTransientNotification("权限已开启", detail: "屏幕录制权限已经可用。")
        } else {
            ScreenPermissionChecker.requestRecordScreenAccess()
            showPermissionAlert()
        }
    }

    @objc private func requestAccessibilityPermissionFromMenu() {
        AppLogger.log("accessibility menu trusted=\(AccessibilityPermissionChecker.isTrusted)")
        if AccessibilityPermissionChecker.isTrusted {
            showTransientNotification("权限已开启", detail: "辅助功能权限已经可用。")
        } else {
            AccessibilityPermissionChecker.requestAccess()
            showError("需要辅助功能权限", detail: "长截图需要辅助功能权限来自动滚动页面。请在系统设置中允许“截图Free”控制电脑；授权后请退出并重新打开应用。")
        }
    }

    @objc private func showSettingsFromMenu() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settingsStore: settingsStore)
        }
        settingsWindowController?.show()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }

    private func startCapture(kind: ScreenshotKind = .area) {
        AppLogger.log("startCapture requested kind=\(kind)")
        Task {
            do {
                let image: NSImage
                switch kind {
                case .area:
                    image = try await systemScreenshotService.captureInteractive()
                case .window:
                    image = try await systemScreenshotService.captureWindow()
                case .fullScreen:
                    image = try await systemScreenshotService.captureFullScreen()
                case .long:
                    await MainActor.run { startLongCapture(mode: .automatic) }
                    return
                }
                AppLogger.log("system screenshot succeeded size=\(image.size)")
                await MainActor.run { edit(image: image) }
            } catch SystemScreenshotError.cancelled {
                AppLogger.log("system screenshot cancelled")
            } catch {
                AppLogger.log("system screenshot failed: \(error.localizedDescription)")
                await MainActor.run { showError("截图失败", detail: error.localizedDescription) }
            }
        }
    }

    private func beginOverlayCapture() {
        AppLogger.log("beginOverlayCapture")
        overlayController?.cancel()
        var controller: CaptureOverlayController?
        controller = CaptureOverlayController { [weak self] result in
            Task { @MainActor in
                guard let self, let controller, self.overlayController === controller else { return }
                self.handleCaptureSelection(result)
            }
        }
        overlayController = controller
        controller?.start()
    }

    private func startLongCapture(mode: LongCaptureMode) {
        guard !isLongCaptureRunning else {
            showTransientNotification("长截图进行中", detail: "请等待当前长截图完成。")
            return
        }

        longCaptureMode = mode
        overlayController?.cancel()
        longCaptureOverlayController?.cancel()
        var controller: CaptureOverlayController?
        controller = CaptureOverlayController { [weak self] result in
            Task { @MainActor in
                guard let self, let controller, self.longCaptureOverlayController === controller else { return }
                self.handleLongCaptureSelection(result)
            }
        }
        longCaptureOverlayController = controller
        controller?.start()
    }

    private func handleLongCaptureSelection(_ result: CaptureSelectionResult) {
        AppLogger.log("handleLongCaptureSelection \(result)")
        longCaptureOverlayController = nil
        guard case let .completed(rect) = result else { return }

        isLongCaptureRunning = true
        manualLongCaptureRect = rect
        manualLongCaptureFrames = []
        AppLogger.log("manual long screenshot started mode=\(longCaptureMode) rect=\(rect)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isLongCaptureRunning else { return }
            let progressOverlay = LongScreenshotProgressOverlayController(selectionRect: rect)
            progressOverlay.onDoubleClickSelection = { [weak self] in
                self?.stopAutomaticLongCapture()
                self?.finishManualLongCapture()
            }
            self.longScreenshotProgressOverlayController = progressOverlay
            progressOverlay.show()
            self.startLongCaptureScrollMonitor()
            self.startLongCaptureKeyMonitor()
            self.captureManualLongFrame()
            if self.longCaptureMode == .automatic {
                self.startAutomaticManualLongCapture()
            }
        }
    }

    private func startRecordingSelection() {
        guard recordingService == nil else {
            showTransientNotification("录屏进行中", detail: "请先完成当前录屏。")
            return
        }

        guard ScreenPermissionChecker.canRecordScreen else {
            ScreenPermissionChecker.requestRecordScreenAccess()
            showPermissionAlert()
            return
        }

        overlayController?.cancel()
        longCaptureOverlayController?.cancel()
        recordingOverlayController?.cancel()
        var controller: CaptureOverlayController?
        controller = CaptureOverlayController { [weak self] result in
            Task { @MainActor in
                guard let self, let controller, self.recordingOverlayController === controller else { return }
                self.handleRecordingSelection(result)
            }
        }
        recordingOverlayController = controller
        controller?.start()
    }

    private func handleRecordingSelection(_ result: CaptureSelectionResult) {
        AppLogger.log("handleRecordingSelection \(result)")
        recordingOverlayController = nil
        guard case let .completed(rect) = result else { return }

        let regionOverlay = RecordingRegionOverlayController(selectionRect: rect)
        recordingRegionOverlayController = regionOverlay
        regionOverlay.show()

        let options = RecordingOptionsWindowController(selectionRect: rect)
        options.onStart = { [weak self] audioSource, quality in
            Task { @MainActor in
                self?.recordingOptionsWindowController?.close()
                self?.recordingOptionsWindowController = nil
                await self?.prepareAndStartRecording(rect: rect, audioSource: audioSource, quality: quality)
            }
        }
        options.onCancel = { [weak self] in
            self?.recordingOptionsWindowController?.close()
            self?.recordingOptionsWindowController = nil
            self?.recordingRegionOverlayController?.close()
            self?.recordingRegionOverlayController = nil
        }
        recordingOptionsWindowController = options
        options.show()
    }

    private func prepareAndStartRecording(rect: CGRect, audioSource: RecordingAudioSource, quality: RecordingQuality) async {
        if audioSource.needsMicrophone && !RecordingPermissionChecker.canRecordMicrophone {
            let granted = await RecordingPermissionChecker.requestMicrophoneAccess()
            guard granted else {
                recordingRegionOverlayController?.close()
                recordingRegionOverlayController = nil
                showError("需要麦克风权限", detail: "请在系统设置 > 隐私与安全性 > 麦克风中允许“截图Free”使用麦克风。")
                return
            }
        }
        await startRecording(rect: rect, audioSource: audioSource, quality: quality)
    }

    private func startRecording(rect: CGRect, audioSource: RecordingAudioSource, quality: RecordingQuality) async {
        let service = ScreenRecordingService()
        recordingService = service
        do {
            _ = try await service.start(rect: rect, audioSource: audioSource, quality: quality)
            let control = RecordingControlWindowController(selectionRect: rect, audioSource: audioSource, quality: quality)
            control.onStop = { [weak self] in
                Task { @MainActor in await self?.finishRecording() }
            }
            recordingControlWindowController = control
            control.show()
            statusItem.button?.toolTip = "录屏进行中"
        } catch {
            recordingService = nil
            recordingRegionOverlayController?.close()
            recordingRegionOverlayController = nil
            AppLogger.log("screen recording start failed: \(error.localizedDescription)")
            showError("录屏失败", detail: error.localizedDescription)
        }
    }

    private func finishRecording() async {
        guard let service = recordingService else { return }
        recordingControlWindowController?.close()
        recordingControlWindowController = nil
        recordingRegionOverlayController?.close()
        recordingRegionOverlayController = nil
        statusItem.button?.toolTip = "截图Free"
        do {
            let url = try await service.stop()
            recordingService = nil
            showRecordingPreview(url: url)
        } catch {
            recordingService = nil
            AppLogger.log("screen recording stop failed: \(error.localizedDescription)")
            showError("录屏失败", detail: error.localizedDescription)
        }
    }

    private func showRecordingPreview(url: URL) {
        let controller = RecordingPreviewWindowController(url: url)
        controller.onClose = { [weak self, weak controller] in
            guard let controller else { return }
            self?.recordingPreviewWindowControllers.removeAll { $0 === controller }
        }
        recordingPreviewWindowControllers.append(controller)
        controller.show()
    }

    private func startLongCaptureScrollMonitor() {
        stopLongCaptureScrollMonitor()
        longCaptureScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let direction: LongScreenshotAppendDirection = event.scrollingDeltaY > 0 ? .up : .down
            Task { @MainActor in self?.scheduleLongCaptureAfterScroll(direction: direction) }
        }
    }

    private func stopLongCaptureScrollMonitor() {
        pendingScrollCapture?.cancel()
        pendingScrollCapture = nil
        if let longCaptureScrollMonitor {
            NSEvent.removeMonitor(longCaptureScrollMonitor)
            self.longCaptureScrollMonitor = nil
        }
    }

    private func scheduleLongCaptureAfterScroll(direction: LongScreenshotAppendDirection) {
        guard isLongCaptureRunning, !manualLongCaptureFrames.isEmpty else { return }
        pendingLongCaptureDirection = direction
        pendingScrollCapture?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.captureManualLongFrame(direction: direction) }
        }
        pendingScrollCapture = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func captureManualLongFrame(direction: LongScreenshotAppendDirection? = nil) {
        guard !isManualLongCaptureCapturing, let rect = manualLongCaptureRect else { return }
        let appendDirection = direction ?? pendingLongCaptureDirection
        isManualLongCaptureCapturing = true
        pendingScrollCapture?.cancel()
        pendingScrollCapture = nil
        let service = captureService
        let coordinatorBox = WeakBox(self)
        AppLogger.log("manual long screenshot capture frame begin rect=\(rect)")
        longCaptureTask = Task.detached(priority: .userInitiated) {
            do {
                await MainActor.run {
                    coordinatorBox.value?.longScreenshotProgressOverlayController?.setSelectionBorderHidden(true)
                }
                try await Task.sleep(nanoseconds: 80_000_000)
                let frame = try service.captureCGImage(rect: rect)
                let coordinator = coordinatorBox.value
                await MainActor.run {
                    guard let coordinator else { return }
                    coordinator.longScreenshotProgressOverlayController?.setSelectionBorderHidden(false)
                    if let previous = coordinator.manualLongCaptureFrames.last,
                       appendDirection == .down,
                       coordinator.automaticLongCaptureTask != nil,
                       coordinator.longScreenshotService.isMostlySame(previous, frame, threshold: 0.003) {
                        coordinator.automaticLongCaptureStableFrameCount += 1
                        AppLogger.log("manual long screenshot reached bottom stableCount=\(coordinator.automaticLongCaptureStableFrameCount)")
                        coordinator.isManualLongCaptureCapturing = false
                        coordinator.longScreenshotProgressOverlayController?.setSelectionBorderHidden(false)
                        if coordinator.automaticLongCaptureStableFrameCount >= 3 {
                            coordinator.stopAutomaticLongCapture()
                            coordinator.finishManualLongCapture()
                        }
                        coordinator.statusItem.button?.toolTip = "长截图检测到底中 \(coordinator.automaticLongCaptureStableFrameCount)/3"
                        return
                    }
                    coordinator.automaticLongCaptureStableFrameCount = 0
                    switch appendDirection {
                    case .down:
                        coordinator.manualLongCaptureFrames.append(frame)
                    case .up:
                        coordinator.manualLongCaptureFrames.insert(frame, at: 0)
                    }
                    coordinator.isManualLongCaptureCapturing = false
                    let frameCount = coordinator.manualLongCaptureFrames.count
                    AppLogger.log("manual long screenshot captured frame=\(frameCount) direction=\(appendDirection) size=\(frame.width)x\(frame.height)")
                    coordinator.updateManualLongCapturePreview()
                    coordinator.longScreenshotProgressOverlayController?.setSelectionBorderHidden(false)
                    coordinator.statusItem.button?.toolTip = "长截图已截取 \(frameCount) 段"
                }
            } catch {
                let coordinator = coordinatorBox.value
                await MainActor.run {
                    coordinator?.isManualLongCaptureCapturing = false
                    coordinator?.longScreenshotProgressOverlayController?.setSelectionBorderHidden(false)
                    AppLogger.log("manual long screenshot capture failed: \(error.localizedDescription)")
                    coordinator?.showTransientNotification("长截图失败", detail: error.localizedDescription)
                }
            }
        }
    }

    private func startAutomaticManualLongCapture() {
        guard AccessibilityPermissionChecker.isTrusted else {
            showTransientNotification("需要辅助功能权限", detail: "自动滚动需要辅助功能权限。未授权时请继续手动滚动。")
            return
        }
        automaticLongCaptureStableFrameCount = 0
        AppLogger.log("manual long screenshot auto scroll started")
        automaticLongCaptureTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { self?.scrollLongCaptureArea(direction: .down) }
                try? await Task.sleep(nanoseconds: 420_000_000)
                await MainActor.run { self?.captureManualLongFrame(direction: .down) }
                try? await Task.sleep(nanoseconds: 620_000_000)
            }
        }
    }

    private func stopAutomaticLongCapture() {
        AppLogger.log("manual long screenshot auto scroll stopped")
        automaticLongCaptureTask?.cancel()
        automaticLongCaptureTask = nil
        automaticLongCaptureStableFrameCount = 0
    }

    private func scrollLongCaptureArea(direction: LongScreenshotAppendDirection) {
        let delta: Int32 = direction == .down ? -420 : 420
        let location = manualLongCaptureRect.map { quartzScreenPoint(for: CGPoint(x: $0.midX, y: $0.midY)) }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else {
            return
        }
        if let location {
            event.location = location
        }
        event.post(tap: .cghidEventTap)
    }

    private func startLongCaptureKeyMonitor() {
        stopLongCaptureKeyMonitor()
        longCaptureKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                guard let self, self.isLongCaptureRunning else { return }
                self.stopAutomaticLongCapture()
                self.finishManualLongCapture()
            }
        }
        longCaptureLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in
                guard let self, self.isLongCaptureRunning else { return }
                self.stopAutomaticLongCapture()
                self.finishManualLongCapture()
            }
            return nil
        }
    }

    private func stopLongCaptureKeyMonitor() {
        if let longCaptureKeyMonitor {
            NSEvent.removeMonitor(longCaptureKeyMonitor)
            self.longCaptureKeyMonitor = nil
        }
        if let longCaptureLocalKeyMonitor {
            NSEvent.removeMonitor(longCaptureLocalKeyMonitor)
            self.longCaptureLocalKeyMonitor = nil
        }
    }

    private func quartzScreenPoint(for appKitPoint: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) ?? NSScreen.main else {
            return appKitPoint
        }
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = screen.deviceDescription[screenNumberKey] as? CGDirectDisplayID else {
            return CGPoint(x: appKitPoint.x, y: screen.frame.maxY - appKitPoint.y)
        }
        let displayBounds = CGDisplayBounds(displayID)
        return CGPoint(
            x: displayBounds.minX + appKitPoint.x - screen.frame.minX,
            y: displayBounds.minY + screen.frame.maxY - appKitPoint.y
        )
    }

    private func finishManualLongCapture() {
        guard !manualLongCaptureFrames.isEmpty else {
            showTransientNotification("长截图尚未开始", detail: "请先等待第一段截取完成。")
            return
        }
        do {
            let image = try longScreenshotService.stitch(frames: manualLongCaptureFrames)
            AppLogger.log("manual long screenshot finished frames=\(manualLongCaptureFrames.count) size=\(image.size)")
            resetLongCaptureState(closeControls: true)
            edit(image: image, allowsZoom: true)
        } catch {
            AppLogger.log("manual long screenshot stitch failed: \(error.localizedDescription)")
            showTransientNotification("长截图失败", detail: error.localizedDescription)
        }
    }

    private func updateManualLongCapturePreview() {
        guard let frame = manualLongCaptureFrames.last else { return }
        let image = NSImage(cgImage: frame, size: CGSize(width: frame.width, height: frame.height))
        longScreenshotProgressOverlayController?.updatePreview(image: image, frameCount: manualLongCaptureFrames.count)
    }

    private func startDiagnosticLongCapture(rect: CGRect) {
        let service = captureService
        let coordinatorBox = WeakBox(self)
        AppLogger.log("diagnostic long screenshot task scheduled rect=\(rect)")
        longCaptureTask = Task.detached(priority: .userInitiated) {
            do {
                AppLogger.log("diagnostic long screenshot captureRegion begin rect=\(rect)")
                let cgImage = try service.captureCGImage(rect: rect)
                let coordinator = coordinatorBox.value
                await MainActor.run {
                    guard let coordinator else { return }
                    let image = NSImage(cgImage: cgImage, size: rect.size)
                    AppLogger.log("diagnostic long screenshot captureRegion succeeded size=\(image.size)")
                    coordinator.resetLongCaptureState(closeControls: true)
                    coordinator.edit(image: image, allowsZoom: true)
                }
            } catch {
                let coordinator = coordinatorBox.value
                await MainActor.run {
                    coordinator?.resetLongCaptureState(closeControls: true)
                    AppLogger.log("diagnostic long screenshot captureRegion failed: \(error.localizedDescription)")
                    coordinator?.showTransientNotification("长截图失败", detail: error.localizedDescription)
                }
            }
        }
    }

    private func cancelLongCapture() {
        AppLogger.log("long screenshot cancelled")
        stopAutomaticLongCapture()
        longCaptureTask?.cancel()
        resetLongCaptureState(closeControls: true)
    }

    private func resetLongCaptureState(closeControls: Bool) {
        isLongCaptureRunning = false
        longCaptureTask = nil
        stopAutomaticLongCapture()
        stopLongCaptureScrollMonitor()
        stopLongCaptureKeyMonitor()
        manualLongCaptureRect = nil
        manualLongCaptureFrames = []
        isManualLongCaptureCapturing = false
        statusItem.button?.toolTip = "截图Free"
        if closeControls {
            longScreenshotProgressOverlayController?.close()
            longScreenshotProgressOverlayController = nil
        }
    }

    private func handleCaptureSelection(_ result: CaptureSelectionResult) {
        AppLogger.log("handleCaptureSelection \(result)")
        overlayController = nil
        guard case let .completed(rect) = result else { return }

        do {
            let image = try captureService.capture(rect: rect)
            edit(image: image)
        } catch {
            AppLogger.log("capture failed: \(error.localizedDescription)")
            showError("截图失败", detail: "如果已经授予“截图Free”屏幕录制权限，请退出并重新打开应用后再试。\n\n\(error.localizedDescription)")
        }
    }

    private func edit(image: NSImage, allowsZoom: Bool = false) {
        let settings = settingsStore.load()
        let controller = AnnotationEditorController(image: image, exportScale: CGFloat(settings.exportScale), allowsZoom: allowsZoom)
        controller.onComplete = { [weak self, weak controller] _ in
            guard let controller else { return }
            self?.annotationEditorControllers.removeAll { $0 === controller }
        }
        controller.onCancel = { [weak self, weak controller] in
            guard let controller else { return }
            self?.annotationEditorControllers.removeAll { $0 === controller }
        }
        controller.onCopy = { image in ClipboardService.copy(image: image) }
        controller.onSave = { [weak self] image in self?.save(image: image) ?? false }
        controller.onPin = { [weak self] image in self?.pin(image: image) }
        controller.onClose = { [weak self, weak controller] in
            guard let controller else { return }
            self?.annotationEditorControllers.removeAll { $0 === controller }
        }
        annotationEditorControllers.append(controller)
        controller.show()
        if settings.autoCopyAfterCapture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak controller] in
                guard let renderedImage = controller?.exportImage() else {
                    ClipboardService.copy(image: image)
                    return
                }
                ClipboardService.copy(image: renderedImage)
            }
        }
    }

    private func save(image: NSImage) -> Bool {
        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.nameFieldStringValue = ScreenshotFileNamer.fileName()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            let data = try ImageEncoding.pngData(from: image)
            try data.write(to: url, options: .atomic)
            showTransientNotification("已保存", detail: url.path)
            return true
        } catch {
            showError("保存失败", detail: error.localizedDescription)
            return false
        }
    }

    private func pin(image: NSImage) {
        let controller = PinWindowController(image: image)
        controller.onClose = { [weak self, weak controller] in
            guard let controller else { return }
            self?.pinnedWindows.removeAll { $0 === controller }
        }
        pinnedWindows.append(controller)
        controller.show()
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在系统设置 > 隐私与安全性 > 屏幕录制中允许“截图Free”，然后重新尝试截图。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    private func showTransientNotification(_ title: String, detail: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
