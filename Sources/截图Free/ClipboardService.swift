import AppKit

@MainActor
protocol ImagePasteboard: AnyObject {
    var changeCount: Int { get }
    func replacePNG(_ data: Data) -> Bool
}

extension NSPasteboard: ImagePasteboard {
    func replacePNG(_ data: Data) -> Bool {
        // 数据已完整编码；这里不能 await、调度或先清空再生成。
        clearContents()
        return setData(data, forType: .png)
    }
}

/// 所有截图窗口共用一个仲裁器。请求时认领意图，而不是编码结束时认领。
@MainActor
final class ClipboardService {
    typealias Render = @Sendable () throws -> Data
    typealias Snapshot = () -> Render?
    struct Request: Equatable {
        let token: UInt64
        let owner: UUID
        let revision: UInt64
        let generation: UInt64
        let expectedChangeCount: Int
        let automatic: Bool
    }
    private let pasteboard: ImagePasteboard
    private let queue = OperationQueue()
    private let delay: TimeInterval
    private var pending: DispatchWorkItem?
    private var operation: Operation?
    private var token: UInt64 = 0
    private var generation: UInt64 = 0
    private var settingsObserver: NSObjectProtocol?
    private(set) var currentRequest: Request?
    private(set) var clipboardOwner: UUID?
    var automaticEnabled = false {
        didSet {
            if oldValue != automaticEnabled {
                generation &+= 1
                if currentRequest?.automatic == true { cancelPending() }
            }
        }
    }

    init(pasteboard: ImagePasteboard = NSPasteboard.general, delay: TimeInterval = 0.18) {
        self.pasteboard = pasteboard
        self.delay = delay
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    func observeSettings(_ store: SettingsStore) {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        automaticEnabled = store.load().autoCopyAfterCapture
        let storeIdentity = ObjectIdentifier(store)
        settingsObserver = NotificationCenter.default.addObserver(forName: SettingsStore.didSave, object: nil, queue: .main) { [weak self] notification in
            guard let source = notification.object as? SettingsStore, ObjectIdentifier(source) == storeIdentity,
                  let settings = notification.userInfo?["settings"] as? AppSettings else { return }
            MainActor.assumeIsolated { self?.automaticEnabled = settings.autoCopyAfterCapture }
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        pending?.cancel()
        queue.cancelAllOperations()
    }

    func cancelPending() {
        token &+= 1
        pending?.cancel(); pending = nil
        operation?.cancel(); operation = nil
        queue.cancelAllOperations()
        currentRequest = nil
    }

    func close(owner: UUID) {
        if currentRequest?.owner == owner { cancelPending() }
        // 关窗不触碰系统内容，也不清除其他窗口的请求。
    }

    @discardableResult
    func request(owner: UUID, revision: UInt64, automatic: Bool = true,
                 snapshot: @escaping Snapshot) -> Request? {
        guard !automatic || automaticEnabled else { return nil }
        cancelPending()
        let request = Request(token: token, owner: owner, revision: revision,
                              generation: generation, expectedChangeCount: pasteboard.changeCount,
                              automatic: automatic)
        currentRequest = request
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isCurrent(request) else {
                if self.currentRequest == request { self.cancelPending() }
                return
            }
            self.pending = nil
            guard let render = snapshot() else {
                self.currentRequest = nil
                return
            }
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                guard operation?.isCancelled == false else { return }
                let result = autoreleasepool { try? render() }
                guard operation?.isCancelled == false else { return }
                DispatchQueue.main.async { [weak self, weak operation] in
                    guard operation?.isCancelled == false else { return }
                    self?.complete(request, data: result)
                }
            }
            self.operation = operation
            self.queue.addOperation(operation)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (automatic ? delay : 0), execute: work)
        return request
    }

    private func isCurrent(_ request: Request) -> Bool {
        currentRequest == request && request.token == token &&
        (!request.automatic || (automaticEnabled && request.generation == generation)) &&
        pasteboard.changeCount == request.expectedChangeCount
    }

    // 内部入口也用于注入延迟/乱序结果测试；真正写入前再次核对全部条件。
    func complete(_ request: Request, data: Data?) {
        guard isCurrent(request) else {
            if currentRequest == request { cancelPending() }
            return
        }
        defer { currentRequest = nil; operation = nil }
        guard let data, !data.isEmpty else { return }
        if pasteboard.replacePNG(data) { clipboardOwner = request.owner }
    }
}
