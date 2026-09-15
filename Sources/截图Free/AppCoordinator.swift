import AppKit
import UserNotifications

private enum ScreenshotKind {
    case area
    case window
    case fullScreen
    case long
}

enum LongCaptureMode {
    case automatic
    case manual
}

struct MenuPermissionStatus {
    let screen: Bool
    let accessibility: Bool
    let microphone: Bool

    // 只查询，不请求授权；每次打开菜单重新读取系统状态。
    static func current() -> Self {
        Self(screen: ScreenPermissionChecker.canRecordScreen,
             accessibility: AccessibilityPermissionChecker.isTrusted,
             microphone: RecordingPermissionChecker.canRecordMicrophone)
    }
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
    private var shortcutRegistrationFactory: () -> ShortcutRegistration = { ShortcutManager() }
    private(set) lazy var shortcutBindings: ShortcutBindings = {
        let bindings = ShortcutBindings(store: settingsStore, factory: shortcutRegistrationFactory, dispatch: { [weak self] action in
            self?.dispatchShortcut(action)
        })
        bindings.onChange = { [weak self] in
            guard let self, let menu = self.statusItem.menu else { return }
            self.rebuildMenu(menu)
        }
        return bindings
    }()
    private let captureService: ScreenCaptureService
    private let postLongScroll: ((Int32, CGPoint) -> Void)?
    private let canAutoScroll: () -> Bool
    private let menuPermissions: () -> MenuPermissionStatus
    private let onLongImage: ((NSImage) -> Void)?
    private var onLongError: ((Error) -> Void)?
    private var stitchLongFrames: (([CGImage]) async throws -> CGImage)?
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
    private(set) var pinnedWindows: [PinWindowController] = []
    private var isLongCaptureRunning = false
    private var longCaptureTask: Task<Void, Never>?
    private var longCaptureFinishTask: Task<Void, Never>?
    private var manualLongCaptureRect: CGRect?
    private var manualLongCapturePlan = LongScreenshotService.StitchPlan()
    private var manualLongCaptureFrames: [StoredCaptureFrame] { manualLongCapturePlan.frames }
    private var isManualLongCaptureCapturing = false
    private var longCaptureScrollMonitor: Any?
    private var longCaptureLocalScrollMonitor: Any?
    private var scrollNeedsCapture = false
    private var scrollGestureInSelection = false
    private var pendingScrollCapture: DispatchWorkItem?
    private var pendingLongCaptureDirection: LongScreenshotAppendDirection = .down
    private var automaticLongCaptureTask: Task<Void, Never>?
    private var automaticLongCaptureStableFrameCount = 0
    private var manualSamplingTask: Task<Void, Never>?
    private var overlapRetryCount = 0
    private var automaticNeedsScroll = true
    private let enableScrollMonitors: Bool
    private var longCaptureKeyMonitor: Any?
    private var longCaptureLocalKeyMonitor: Any?
    private var longCaptureMode: LongCaptureMode = .manual
    private var longCaptureSession = UUID()
    private var isLongCaptureFinishing = false
    // 恢复也会设置 finishing；只有显式完成请求可放弃未验证尾部。
    private var longCaptureFinishRequested = false
    private(set) var longCaptureLastNotice: String?

    override init() {
        captureService = ScreenCaptureService()
        postLongScroll = nil
        enableScrollMonitors = true
        canAutoScroll = { AccessibilityPermissionChecker.isTrusted }
        menuPermissions = MenuPermissionStatus.current
        onLongImage = nil
        let supportURL = FileManager.default.applicationSupportDirectory
            .appendingPathComponent("截图Free", isDirectory: true)
        settingsStore = SettingsStore(fileURL: supportURL.appendingPathComponent("settings.json"))
        super.init()
    }

    // 注入捕获/滚动边界，回归测试不读取桌面、不向其他应用发送事件或保存用户数据。
    init(captureService: ScreenCaptureService, settingsStore: SettingsStore,
         postLongScroll: @escaping (Int32, CGPoint) -> Void,
         onLongImage: ((NSImage) -> Void)?, onLongError: ((Error) -> Void)? = nil,
         stitchLongFrames: (([CGImage]) async throws -> CGImage)? = nil,
          menuPermissions: @escaping () -> MenuPermissionStatus = MenuPermissionStatus.current,
           enableScrollMonitors: Bool = true,
           shortcutRegistrationFactory: @escaping () -> ShortcutRegistration = { ShortcutManager() }) {
        self.captureService = captureService
        self.settingsStore = settingsStore
        self.shortcutRegistrationFactory = shortcutRegistrationFactory
        self.postLongScroll = postLongScroll
        self.enableScrollMonitors = enableScrollMonitors
        self.canAutoScroll = { true }
        self.menuPermissions = menuPermissions
        self.onLongImage = onLongImage
        self.onLongError = onLongError
        self.stitchLongFrames = stitchLongFrames
        super.init()
    }

    var longCaptureIsRunning: Bool { isLongCaptureRunning }
    var longCaptureProgressOverlay: LongScreenshotProgressOverlayController? { longScreenshotProgressOverlayController }
    var longCaptureFrameCount: Int { manualLongCaptureFrames.count }
    var retainedEditors: [AnnotationEditorController] { annotationEditorControllers }
    var longCaptureResourcesAreReset: Bool {
        !isLongCaptureRunning && !isLongCaptureFinishing && !isManualLongCaptureCapturing &&
        longCaptureTask == nil && longCaptureFinishTask == nil && automaticLongCaptureTask == nil && manualSamplingTask == nil &&
        longCaptureOverlayController == nil && longScreenshotProgressOverlayController == nil &&
        manualLongCaptureRect == nil && manualLongCaptureFrames.isEmpty && pendingScrollCapture == nil &&
        longCaptureScrollMonitor == nil && longCaptureLocalScrollMonitor == nil &&
        !scrollNeedsCapture && longCaptureKeyMonitor == nil && longCaptureLocalKeyMonitor == nil
    }

    func beginLongCapture(rect: CGRect, mode: LongCaptureMode) {
        guard !isLongCaptureRunning else { return }
        longCaptureMode = mode
        handleLongCaptureSelection(.completed(rect))
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        logRuntimeIdentity()
        configureMenuBar()
        registerShortcut()
    }

    func stop() {
        shortcutBindings.stop()
        cancelLongCapture()
        // 回调会移除数组元素，遍历快照以免跳过其他贴图。
        for controller in pinnedWindows { controller.close() }
    }

    func configureMenuBar() {
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
        AppLogger.log("runtime identity bundleID=\(bundleID) version=\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") build=\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown") bundlePath=\(bundlePath) executable=\(executablePath) screenPreflight=\(ScreenPermissionChecker.canRecordScreen) accessibility=\(AccessibilityPermissionChecker.isTrusted) inputMonitoring=\(CGPreflightListenEventAccess())")
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    var mainStatusMenu: NSMenu? { statusItem.menu }

    private func rebuildMenu(_ menu: NSMenu) {
        let permissions = menuPermissions()
        menu.removeAllItems()

        for (granted, title) in [(permissions.screen, "录屏权限：未开启"),
                                 (permissions.accessibility, "辅助功能权限：未开启"),
                                 (permissions.microphone, "麦克风权限：未开启")] where !granted {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if !permissions.screen {
            menu.addItem(NSMenuItem(title: "请求屏幕录制权限", action: #selector(requestScreenPermissionFromMenu), keyEquivalent: ""))
        }

        if !permissions.accessibility {
            menu.addItem(NSMenuItem(title: "请求辅助功能权限", action: #selector(requestAccessibilityPermissionFromMenu), keyEquivalent: ""))
        }

        if !menu.items.isEmpty { menu.addItem(NSMenuItem.separator()) }
        let selectors: [Selector] = [#selector(startCaptureFromMenu), #selector(startWindowCaptureFromMenu),
            #selector(startFullScreenCaptureFromMenu), #selector(startAutomaticLongCaptureFromMenu),
            #selector(startManualLongCaptureFromMenu), #selector(startRecordingFromMenu)]
        for (action, selector) in zip(ShortcutAction.allCases, selectors) {
            let shortcut = settingsStore.load().shortcut(for: action)
            let equivalent = shortcut?.menuKeyEquivalent
            let title = action.title + (shortcut != nil && equivalent == nil ? "    \(shortcut!.displayString)" : "")
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: equivalent ?? "")
            item.keyEquivalentModifierMask = equivalent == nil ? [] : (shortcut?.modifierFlags ?? [])
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "设置", action: #selector(showSettingsFromMenu), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        if isLongCaptureRunning {
            menu.addItem(NSMenuItem(title: "完成当前长截图", action: #selector(finishLongCaptureFromMenu), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "取消当前长截图", action: #selector(cancelLongCaptureFromMenu), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitFromMenu), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
    }

    private func registerShortcut() {
        shortcutBindings.start()
    }

    private func dispatchShortcut(_ action: ShortcutAction) {
        guard !shortcutBindings.isSuspended else { return }
        // 快捷键只启动，不切换/结束会话，也不撤销其他捕获选区。
        guard !isLongCaptureRunning, longCaptureOverlayController == nil,
              recordingService == nil, recordingOverlayController == nil,
              recordingOptionsWindowController == nil, overlayController == nil else { return }
        switch action {
        case .area: startCapture(kind: .area)
        case .window: startCapture(kind: .window)
        case .fullScreen: startCapture(kind: .fullScreen)
        case .automaticLong: startLongCapture(mode: .automatic)
        case .manualLong: startLongCapture(mode: .manual)
        case .recording: startRecordingSelection()
        }
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
            settingsWindowController = SettingsWindowController(settingsStore: settingsStore, bindings: shortcutBindings)
        }
        settingsWindowController?.show()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func finishLongCaptureFromMenu() { finishManualLongCapture() }
    @objc private func cancelLongCaptureFromMenu() { cancelLongCapture() }

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
        let controllerBox = WeakBox<CaptureOverlayController>(nil)
        let controller = CaptureOverlayController { [weak self] result in
            Task { @MainActor in
                guard let self, let controller = controllerBox.value,
                      self.longCaptureOverlayController === controller else { return }
                self.handleLongCaptureSelection(result)
            }
        }
        controllerBox.value = controller
        longCaptureOverlayController = controller
        controller.start()
    }

    private func handleLongCaptureSelection(_ result: CaptureSelectionResult) {
        AppLogger.log("handleLongCaptureSelection \(result)")
        longCaptureOverlayController = nil
        guard case let .completed(rect) = result else { return }

        isLongCaptureRunning = true
        longCaptureLastNotice = nil
        longCaptureSession = UUID()
        isLongCaptureFinishing = false
        pendingLongCaptureDirection = .down
        let session = longCaptureSession
        manualLongCaptureRect = rect
        manualLongCapturePlan = LongScreenshotService.StitchPlan()
        AppLogger.log("manual long screenshot started mode=\(longCaptureMode) rect=\(rect)")
        startLongCaptureScrollMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isLongCaptureRunning, !self.isLongCaptureFinishing,
                  self.longCaptureSession == session else { return }
            let progressOverlay = LongScreenshotProgressOverlayController(selectionRect: rect)
            progressOverlay.onDoubleClickSelection = self.longCaptureFinishAction(session: session)
            self.longScreenshotProgressOverlayController = progressOverlay
            progressOverlay.show()
            self.startLongCaptureKeyMonitor()
            self.captureManualLongFrame()
            self.startManualSampling()
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
        options.onStart = { [weak self, weak options] audioSource, quality in
            Task { @MainActor in
                guard let self, let options, self.recordingOptionsWindowController === options else { return }
                options.close()
                self.recordingOptionsWindowController = nil
                await self.prepareAndStartRecording(rect: rect, audioSource: audioSource, quality: quality)
            }
        }
        options.onCancel = { [weak self, weak options] in
            guard let options, self?.recordingOptionsWindowController === options else { return }
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
            control.onStop = { [weak self, weak service] in
                Task { @MainActor in
                    guard let service else { return }
                    await self?.finishRecording(service: service)
                }
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

    private func finishRecording(service: ScreenRecordingService) async {
        guard recordingService === service else { return }
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
        guard enableScrollMonitors else { return }
        let session = longCaptureSession
        longCaptureScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            Task { @MainActor in
                guard let self, self.longCaptureSession == session else { return }
                self.handleLongCaptureScroll(event)
            }
        }
        longCaptureLocalScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, self.longCaptureSession == session { self.handleLongCaptureScroll(event) }
            return event
        }
        AppLogger.log("long scroll monitors session=\(session) global=\(longCaptureScrollMonitor != nil) local=\(longCaptureLocalScrollMonitor != nil)")
    }

    func handleLongCaptureScroll(_ event: NSEvent) {
        // 使用事件自身的位置，而非异步处理时已经移走的鼠标位置。
        let point: CGPoint
        if let window = event.window {
            point = window.convertPoint(toScreen: event.locationInWindow)
        } else if let cg = event.cgEvent, let primary = CaptureDisplay.current().first {
            point = CGPoint(x: cg.location.x, y: primary.frame.maxY - cg.location.y)
        } else {
            point = event.locationInWindow
        }
        handleLongCaptureScroll(deltaY: event.scrollingDeltaY, point: point,
                                phase: event.phase, momentum: event.momentumPhase)
    }

    func handleLongCaptureScroll(deltaY: CGFloat, point: CGPoint, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) {
        guard isLongCaptureRunning, !isLongCaptureFinishing,
              longCaptureMode == .manual || automaticLongCaptureTask == nil else { return }
        let inside = manualLongCaptureRect?.contains(point) == true
        if phase.contains(.began) { scrollGestureInSelection = inside }
        guard inside || (scrollGestureInSelection && (!phase.isEmpty || !momentum.isEmpty)) else { return }
        if deltaY != 0 || phase.contains(.ended) || momentum.contains(.ended) {
            // delta 已由系统应用自然滚动设置；只作提示，最终顺序由像素匹配决定。
            scheduleLongCaptureAfterScroll(direction: deltaY == 0 ? pendingLongCaptureDirection : (deltaY > 0 ? .up : .down))
        }
        if momentum.contains(.ended) || phase.contains(.cancelled) { scrollGestureInSelection = false }
    }

    private func stopLongCaptureScrollMonitor() {
        pendingScrollCapture?.cancel()
        pendingScrollCapture = nil
        if let monitor = longCaptureLocalScrollMonitor {
            NSEvent.removeMonitor(monitor)
            longCaptureLocalScrollMonitor = nil
        }
        if let longCaptureScrollMonitor {
            NSEvent.removeMonitor(longCaptureScrollMonitor)
            self.longCaptureScrollMonitor = nil
        }
    }

    // 全局滚轮只是加速提示。无辅助功能/Input Monitoring、鼠标移出选区时仍采图。
    // 完成一次捕获及匹配后才启动下一周期，不积压位图或定时回调；静态上限约 2Hz。
    private func startManualSampling() {
        guard manualSamplingTask == nil else { return }
        let session = longCaptureSession
        manualSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
                guard let self, self.longCaptureSession == session,
                      self.isLongCaptureRunning, !self.isLongCaptureFinishing else { return }
                if self.automaticLongCaptureTask == nil {
                    self.captureManualLongFrame()
                    await self.longCaptureTask?.value
                }
            }
        }
    }

    func scheduleLongCaptureAfterScroll(direction: LongScreenshotAppendDirection) {
        guard isLongCaptureRunning, !isLongCaptureFinishing else { return }
        guard automaticLongCaptureTask == nil else { return }
        if !scrollNeedsCapture {
            AppLogger.log("long scroll queued session=\(longCaptureSession) hint=\(direction) capturing=\(isManualLongCaptureCapturing) frames=\(manualLongCaptureFrames.count)")
        }
        scrollNeedsCapture = true
        pendingLongCaptureDirection = direction
        guard !manualLongCaptureFrames.isEmpty else { return }
        // 节流而非尾沿防抖：持续滚动也必须采样，不能一直等到停止。
        guard pendingScrollCapture == nil else { return }
        let session = longCaptureSession
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.longCaptureSession == session, !self.isLongCaptureFinishing else { return }
                self.pendingScrollCapture = nil
                if self.isManualLongCaptureCapturing {
                    self.scheduleLongCaptureAfterScroll(direction: self.pendingLongCaptureDirection)
                } else {
                    self.captureManualLongFrame()
                }
            }
        }
        pendingScrollCapture = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func captureManualLongFrame(direction: LongScreenshotAppendDirection? = nil) {
        guard isLongCaptureRunning, !isManualLongCaptureCapturing, let rect = manualLongCaptureRect else { return }
        let appendDirection = direction ?? pendingLongCaptureDirection
        let session = longCaptureSession
        isManualLongCaptureCapturing = true
        if !manualLongCaptureFrames.isEmpty { scrollNeedsCapture = false }
        pendingScrollCapture?.cancel()
        pendingScrollCapture = nil
        let service = captureService
        let frames = manualLongCaptureFrames
        let matcher = longScreenshotService
        let plan = manualLongCapturePlan
        let excludedWindows = longScreenshotProgressOverlayController?.captureWindowIDs ?? []
        let coordinatorBox = WeakBox(self)
        AppLogger.log("manual long screenshot capture frame begin rect=\(rect)")
        longCaptureTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let frame = try service.captureCGImage(rect: rect, excludingWindowIDs: excludedWindows)
                try Task.checkCancellation()
                // 明确阶段生命周期：匹配临时解码与存储缓冲必须在预览分配前释放。
                let merged = try autoreleasepool { try matcher.merging(frame: frame, into: plan) }
                let duplicate = merged.frames.count == frames.count
                let preview = duplicate ? nil : try matcher.stitch(plan: merged, maximumPreviewDimension: 840)
                let coordinator = coordinatorBox.value
                try Task.checkCancellation()
                await MainActor.run {
                    guard let coordinator, coordinator.longCaptureSession == session, coordinator.isLongCaptureRunning else { return }
                    // 已完成的采帧任务先解除引用，错误/完成处理不得取消正在回调的任务。
                    coordinator.longCaptureTask = nil
                    defer {
                        if coordinator.scrollNeedsCapture, !coordinator.isLongCaptureFinishing {
                            coordinator.scheduleLongCaptureAfterScroll(direction: coordinator.pendingLongCaptureDirection)
                        }
                    }
                    coordinator.overlapRetryCount = 0
                    if appendDirection == .down,
                       coordinator.automaticLongCaptureTask != nil,
                       duplicate {
                        coordinator.automaticLongCaptureStableFrameCount += 1
                        AppLogger.log("long capture unchanged; bottom unconfirmed samples=\(coordinator.automaticLongCaptureStableFrameCount)")
                        coordinator.isManualLongCaptureCapturing = false
                        if coordinator.automaticLongCaptureStableFrameCount >= 8, !coordinator.isLongCaptureFinishing {
                            coordinator.stopAutomaticLongCapture()
                            if frames.count > 1 {
                                // 有可信位移且连续无新增：直接交付当前计划，不再重采引入动画尾帧。
                                coordinator.finishVerifiedAutomaticCapture()
                            } else {
                                coordinator.manualSamplingTask?.cancel()
                                coordinator.manualSamplingTask = nil
                                coordinator.longScreenshotProgressOverlayController?.setStatus("页面未变化，可手动滚动或完成。")
                            }
                        }
                        coordinator.statusItem.button?.toolTip = "页面未变化，尚未确认到底；可手动滚动或完成"
                        return
                    }
                    coordinator.automaticLongCaptureStableFrameCount = 0
                    if duplicate {
                        coordinator.isManualLongCaptureCapturing = false
                        return
                    }
                    coordinator.manualLongCapturePlan = merged
                    coordinator.automaticNeedsScroll = true
                    coordinator.longScreenshotProgressOverlayController?.setStatus(nil)
                    coordinator.isManualLongCaptureCapturing = false
                    let frameCount = coordinator.manualLongCaptureFrames.count
                    AppLogger.log("manual long screenshot captured frame=\(frameCount) direction=\(appendDirection) size=\(frame.width)x\(frame.height)")
                    if let preview {
                        coordinator.longScreenshotProgressOverlayController?.updatePreview(image: preview, frameCount: frameCount)
                    }
                    coordinator.statusItem.button?.toolTip = "长截图已截取 \(frameCount) 段"
                    if frameCount == 1, coordinator.longCaptureMode == .automatic, !coordinator.isLongCaptureFinishing {
                        coordinator.startAutomaticManualLongCapture()
                    }
                }
            } catch {
                let coordinator = coordinatorBox.value
                await MainActor.run {
                    guard let coordinator, coordinator.longCaptureSession == session else { return }
                    coordinator.longCaptureTask = nil
                    coordinator.isManualLongCaptureCapturing = false
                    AppLogger.log("manual long screenshot capture failed: \(error.localizedDescription)")
                    if case LongScreenshotError.untrustedOverlap = error,
                       coordinator.longCaptureFinishRequested, !frames.isEmpty {
                        // 包括点击完成时仍在途的采样。保留原计划，交由完成任务
                        // 正常渲染；不能把捕获、存储或渲染失败当作尾帧不匹配。
                         AppLogger.log("long explicit finish retained validated frames=\(frames.count); rejected untrusted tail")
                         coordinator.longCaptureLastNotice = "已按当前内容结束，尾部未确认。"
                         return
                    }
                    if case LongScreenshotError.untrustedOverlap = error, !frames.isEmpty,
                       !coordinator.isLongCaptureFinishing {
                        coordinator.overlapRetryCount += 1
                        coordinator.automaticNeedsScroll = false
                        coordinator.longScreenshotProgressOverlayController?.setStatus("正在重采，请暂停滚动。")
                        AppLogger.log("long overlap retry session=\(session) attempt=\(coordinator.overlapRetryCount)/6 retained=\(frames.count)")
                        if coordinator.overlapRetryCount < 6 { return }
                    }
                    coordinator.failLongCapture(error)
                }
            }
        }
    }

    private func startAutomaticManualLongCapture() {
        guard canAutoScroll() else {
            showTransientNotification("需要辅助功能权限", detail: "自动滚动需要辅助功能权限。未授权时请继续手动滚动。")
            return
        }
        automaticLongCaptureStableFrameCount = 0
        automaticNeedsScroll = true
        AppLogger.log("manual long screenshot auto scroll started")
        let session = longCaptureSession
        automaticLongCaptureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.longCaptureSession == session, self.isLongCaptureRunning, !self.isLongCaptureFinishing else { return }
                await self.longCaptureTask?.value
                guard !Task.isCancelled, self.longCaptureSession == session, !self.isLongCaptureFinishing else { return }
                if self.automaticNeedsScroll {
                    self.automaticNeedsScroll = false
                    do { try await self.scrollLongCaptureArea(direction: .down) }
                    catch is CancellationError { return }
                    catch { self.failLongCapture(error); return }
                }
                // 未确认本次位移前只重新采样，不能越滚越远丢失重叠。
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                guard !Task.isCancelled, self.longCaptureSession == session, !self.isLongCaptureFinishing else { return }
                self.captureManualLongFrame(direction: .down)
                await self.longCaptureTask?.value
                do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            }
        }
    }

    private func stopAutomaticLongCapture() {
        AppLogger.log("manual long screenshot auto scroll stopped")
        automaticLongCaptureTask?.cancel()
        automaticLongCaptureTask = nil
        automaticLongCaptureStableFrameCount = 0
    }

    private func scrollLongCaptureArea(direction: LongScreenshotAppendDirection) async throws {
        guard let rect = manualLongCaptureRect else { return }
        // 滚轮事件使用选区逻辑高度，不能把 Retina 位图高度再当作事件距离。
        // 实际内容位移由匹配器逐像素求解，不假设事件 delta 等于截图像素位移。
        let step = LongScreenshotService.scrollStep(height: rect.height)
        let delta: Int32 = direction == .down ? -step : step
        AppLogger.log("long scroll requested logicalHeight=\(rect.height) delta=\(delta) framePixels=\(manualLongCaptureFrames.last?.height ?? 0)")
        let location = manualLongCaptureRect.map { quartzScreenPoint(for: CGPoint(x: $0.midX, y: $0.midY)) }
        try await SmoothScroll.run(delta: delta) { segment in
            guard let location else { throw ScreenCaptureError.failed }
            if let postLongScroll { postLongScroll(segment, location); return }
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: segment, wheel2: 0, wheel3: 0) else {
                throw ScreenCaptureError.failed
            }
            event.location = location
            event.post(tap: .cghidEventTap)
        }
    }

    private func startLongCaptureKeyMonitor() {
        stopLongCaptureKeyMonitor()
        let finish = longCaptureFinishAction(session: longCaptureSession)
        longCaptureKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                guard self != nil else { return }
                finish()
            }
        }
        longCaptureLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in
                guard self != nil else { return }
                finish()
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

    private func longCaptureFinishAction(session: UUID) -> () -> Void {
        { [weak self] in
            guard let self, self.longCaptureSession == session else { return }
            self.finishManualLongCapture()
        }
    }

    func finishManualLongCapture() {
        guard isLongCaptureRunning, !isLongCaptureFinishing else { return }
        longCaptureFinishRequested = true
        isLongCaptureFinishing = true
        manualSamplingTask?.cancel()
        manualSamplingTask = nil
        stopAutomaticLongCapture()
        stopLongCaptureScrollMonitor()
        stopLongCaptureKeyMonitor()
        let session = longCaptureSession
        let inFlight = longCaptureTask
        longCaptureFinishTask = Task { [weak self] in
            await inFlight?.value
            guard let self, self.longCaptureSession == session, self.isLongCaptureRunning else { return }
            // 停止滚动后再取一次尾帧，包括自动滚动等待中按 Esc 的情况。
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard self.longCaptureSession == session, self.isLongCaptureRunning else { return }
            self.captureManualLongFrame()
            await self.longCaptureTask?.value
            guard self.longCaptureSession == session, self.isLongCaptureRunning else { return }
            await self.completeManualLongCapture()
        }
    }

    private func finishVerifiedAutomaticCapture() {
        guard isLongCaptureRunning, !isLongCaptureFinishing else { return }
        // 自动无新增不是用户放弃尾部，不能设置 explicit finish 标记。
        isLongCaptureFinishing = true
        manualSamplingTask?.cancel()
        manualSamplingTask = nil
        stopLongCaptureScrollMonitor()
        stopLongCaptureKeyMonitor()
        AppLogger.log("long automatic stop reason=verified-no-new-content frames=\(manualLongCaptureFrames.count); pageBottom=unconfirmed")
        longCaptureFinishTask = Task { [weak self] in await self?.completeManualLongCapture() }
    }

    private func completeManualLongCapture() async {
        let session = longCaptureSession
        let frames = manualLongCaptureFrames
        let plan = manualLongCapturePlan
        let service = longScreenshotService
        do {
            guard !frames.isEmpty else { throw LongScreenshotError.noFramesCaptured }
            let bitmap: CGImage
            if let stitchLongFrames {
                bitmap = try await stitchLongFrames(frames.map { try $0.load() })
            } else {
                bitmap = try await Task.detached(priority: .userInitiated) {
                    let image = try service.stitch(plan: plan)
                    guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        throw LongScreenshotError.noFramesCaptured
                    }
                    return bitmap
                }.value
            }
            guard longCaptureSession == session, isLongCaptureRunning else { return }
            let image = NSImage(cgImage: bitmap, size: CGSize(width: bitmap.width, height: bitmap.height))
            AppLogger.log("manual long screenshot finished frames=\(manualLongCaptureFrames.count) size=\(image.size)")
            let notice = longCaptureLastNotice
            longCaptureFinishTask = nil
            resetLongCaptureState(closeControls: true)
            if let onLongImage { onLongImage(image) } else { edit(image: image, allowsZoom: true) }
            if let notice, onLongImage == nil { showLongCaptureNotice(notice) }
        } catch {
            guard longCaptureSession == session else { return }
            AppLogger.log("manual long screenshot stitch failed: \(error.localizedDescription)")
            longCaptureFinishTask = nil
            failLongCapture(error)
        }
    }

    private func failLongCapture(_ error: Error) {
        // 优先交付已验证的连续长图，而不是把成功的拼接拆散成多张截图。
        let frames = manualLongCaptureFrames
        let plan = manualLongCapturePlan
        let service = longScreenshotService
        resetLongCaptureState(closeControls: true)
        let recoverySession = longCaptureSession
        isLongCaptureRunning = true
        isLongCaptureFinishing = true
        AppLogger.log("long screenshot recovery originalFrames=\(frames.count) error=\(error.localizedDescription)")
        longCaptureFinishTask = Task { [self] in
            let partial = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let image = try? service.stitch(plan: plan) else { return nil }
                return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }.value
            guard !Task.isCancelled, longCaptureSession == recoverySession else { return }
            longCaptureFinishTask = nil
            if partial == nil, !frames.isEmpty {
                // 渲染失败不销毁唯一磁盘快照；保留会话，可重试完成或明确取消。
                manualLongCapturePlan = plan
                isLongCaptureFinishing = false
                AppLogger.log("long recovery retained_on_disk frames=\(frames.count) diskBytes=\(plan.diskBytes) rendered=false")
                if let onLongError { onLongError(error) }
                else { showLongCaptureNotice("暂未生成图片，已保留采集内容，可重试完成。") }
                return
            }
            resetLongCaptureState(closeControls: true)
            // 不再在失败恢复中一次性解码全部历史帧。
            let recovered = (partial.map { [$0] } ?? []).map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) }
            for image in recovered {
                if let onLongImage { onLongImage(image) } else { edit(image: image, allowsZoom: true) }
            }
            let notice = Self.longCaptureFailureNotice(error, hasImage: partial != nil)
            longCaptureLastNotice = notice
            if let onLongError { onLongError(error) }
            else { showLongCaptureNotice(notice) }
        }
    }

    static func longCaptureFailureNotice(_ error: Error, hasImage: Bool) -> String {
        let reason: String
        switch error {
        case LongScreenshotError.untrustedOverlap: reason = "尾部重叠未确认"
        case LongScreenshotError.memoryLimit, LongScreenshotError.resourceLimit, LongScreenshotError.inputLimit: reason = "已达安全上限"
        case ScreenCaptureError.screenRecordingPermissionRequired: reason = "请开启屏幕录制权限"
        case let error as CocoaError where error.code == .fileWriteOutOfSpace: reason = "磁盘空间不足"
        default: reason = "采集或生成图片失败"
        }
        return reason + (hasImage ? "，已保留连续内容，请检查尾部。" : "，未生成图片，请重试。")
    }

    private func showLongCaptureNotice(_ notice: String) {
        longCaptureLastNotice = notice
        statusItem.button?.toolTip = notice
        showTransientNotification("长截图", detail: notice)
    }

    func cancelLongCapture() {
        AppLogger.log("long screenshot cancelled")
        resetLongCaptureState(closeControls: true)
    }

    private func resetLongCaptureState(closeControls: Bool) {
        AppLogger.log("long screenshot reset session=\(longCaptureSession) frames=\(manualLongCaptureFrames.count)")
        longCaptureSession = UUID()
        manualSamplingTask?.cancel()
        manualSamplingTask = nil
        overlapRetryCount = 0
        automaticNeedsScroll = true
        longCaptureFinishRequested = false
        isLongCaptureFinishing = false
        isLongCaptureRunning = false
        longCaptureTask?.cancel()
        longCaptureTask = nil
        longCaptureFinishTask?.cancel()
        longCaptureFinishTask = nil
        stopAutomaticLongCapture()
        stopLongCaptureScrollMonitor()
        stopLongCaptureKeyMonitor()
        manualLongCaptureRect = nil
        manualLongCapturePlan = LongScreenshotService.StitchPlan()
        pendingLongCaptureDirection = .down
        scrollNeedsCapture = false
        scrollGestureInSelection = false
        isManualLongCaptureCapturing = false
        statusItem.button?.toolTip = "截图Free"
        if closeControls {
            let selection = longCaptureOverlayController
            longCaptureOverlayController = nil
            let progress = longScreenshotProgressOverlayController
            longScreenshotProgressOverlayController = nil
            selection?.cancel()
            progress?.close()
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

    func pin(image: NSImage) {
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
