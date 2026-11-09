import AppKit
import ImageIO
import UniformTypeIdentifiers
import QuartzCore

// 所有输入均为 AppKit 全局坐标；不把 Dock 留白当作菜单栏高度。
enum ShelfGeometry {
    static func hotRect(frame: CGRect, menuHeight: CGFloat, safeTop: CGFloat = 0, left: CGRect? = nil, right: CGRect? = nil) -> CGRect {
        var center = frame.midX, width = min(300, frame.width * 0.8)
        if safeTop > 0, let left, let right, right.minX > left.maxX,
           left.maxX >= frame.minX, right.minX <= frame.maxX {
            center = (left.maxX + right.minX) / 2
            width = right.minX - left.maxX + 80
        }
        let lo = max(frame.minX, center - width / 2), hi = min(frame.maxX, center + width / 2)
        return CGRect(x: lo, y: frame.maxY - max(4, menuHeight), width: max(0, hi - lo), height: max(4, menuHeight))
    }
    static func topHit(_ point: CGPoint, frame: CGRect, menuHeight: CGFloat, safeTop: CGFloat = 0, left: CGRect? = nil, right: CGRect? = nil) -> Bool {
        let r = hotRect(frame: frame, menuHeight: menuHeight, safeTop: safeTop, left: left, right: right)
        return point.x >= r.minX && point.x < r.maxX && point.y <= r.maxY && point.y >= r.minY
    }
    static func usable(frame: CGRect, visible: CGRect, menuHeight: CGFloat, safeTop: CGFloat) -> CGRect {
        let top = min(visible.maxY, frame.maxY - max(menuHeight, safeTop))
        return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: max(0, top - visible.minY))
    }
    static func sag(_ fraction: CGFloat, width: CGFloat = 1000) -> CGFloat { min(30, width * 0.018) * 4 * fraction * (1 - fraction) }
    static func ropeY(x: CGFloat, screen: CGRect, top: CGFloat) -> CGFloat {
        top - 10 - sag((x - screen.minX) / screen.width, width: screen.width)
    }
    static func photoSize(_ size: CGSize) -> CGSize {
        let scale = min(136 / max(1, size.width), 104 / max(1, size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    static func pivot(_ bounds: CGRect) -> CGPoint { CGPoint(x: bounds.midX, y: clip(bounds).maxY - 4) }
    static func paper(_ bounds: CGRect) -> CGRect { bounds.insetBy(dx: 5, dy: 0).insetBy(dx: 0, dy: 12) }
    static func clip(_ bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - 8, y: bounds.maxY - 13, width: 16, height: 8)
    }
}

struct ShelfHoverState {
    enum Action { case none, open, close }
    private(set) var entered: TimeInterval?
    private(set) var exited: TimeInterval?
    private(set) var blocked = false
    mutating func reset(block: Bool = true) { entered = nil; exited = nil; blocked = block }
    mutating func step(now: TimeInterval, top: Bool, inside: Bool, visible: Bool, busy: Bool = false, clickedTop: Bool = false) -> Action {
        if !top { blocked = false; entered = nil }
        if clickedTop { reset(); return visible ? .close : .none }
        if busy { entered = nil; exited = nil; return .none }
        if visible {
            entered = nil
            exited = nil // 有图展开后仅显式关闭，离开不是关闭动作。
        } else if top && !blocked {
            if entered == nil { entered = now }
            if now - entered! >= 0.12 { entered = nil; exited = nil; return .open }
        }
        return .none
    }
}

enum ShelfMotion {
    static let duration: TimeInterval = 0.82
    static let closingDuration: TimeInterval = 0.58
    private static let frequency: CGFloat = 8
    private static let damping: CGFloat = 5.6
    private static let dampedFrequency = sqrt(frequency * frequency - damping * damping)

    static func offset(target: CGFloat, start: CGFloat, velocity: CGFloat, seconds: CGFloat) -> CGFloat {
        let envelope = exp(-damping * seconds)
        let a = start - target
        let b = (velocity + damping * a) / dampedFrequency
        return target + envelope * (a * cos(dampedFrequency * seconds) + b * sin(dampedFrequency * seconds))
    }

    static func velocity(target: CGFloat, start: CGFloat, velocity: CGFloat, seconds: CGFloat) -> CGFloat {
        let envelope = exp(-damping * seconds)
        let a = start - target
        let b = (velocity + damping * a) / dampedFrequency
        let derivative = -a * dampedFrequency * sin(dampedFrequency * seconds)
            + b * dampedFrequency * cos(dampedFrequency * seconds)
            - damping * (a * cos(dampedFrequency * seconds) + b * sin(dampedFrequency * seconds))
        return envelope * derivative
    }

    static func keyframes(start: CGFloat, target: CGFloat, velocity: CGFloat, duration: TimeInterval, intervals: Int = 120) -> [CGFloat] {
        (0...intervals).map { index in
            if index == intervals { return target }
            let seconds = CGFloat(duration) * CGFloat(index) / CGFloat(intervals)
            return offset(target: target, start: start, velocity: velocity, seconds: seconds)
        }
    }

    static func sample(_ t: CGFloat, closing: Bool, distance: CGFloat, reduceMotion: Bool) -> (offset: CGFloat, flex: CGFloat, opacity: CGFloat) {
        let t = min(1, max(0, t))
        if reduceMotion { return (closing ? distance : 0, 0, 1) }
        let seconds = CGFloat(closing ? closingDuration : duration) * t
        let target = closing ? distance : 0
        let offset = self.offset(target: target, start: closing ? 0 : distance, velocity: 0, seconds: seconds)
        // Keep the rope's established curve; reveal motion carries the whole
        // hanging assembly instead of twisting each photo independently.
        let ropeFlex = (closing ? 1 : -1) * 0.025 * exp(-damping * seconds) * sin(dampedFrequency * seconds)
        return (offset, ropeFlex, 1)
    }
    static func restingAngle(for id: UUID) -> CGFloat {
        let seed = id.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let normalized = CGFloat(seed % 10_001) / 5_000 - 1
        return normalized * 1.7 * .pi / 180
    }
    static func offsets(reduceMotion: Bool) -> [CGFloat] { reduceMotion ? [0] : [180, 0] }
    static func angles(reduceMotion: Bool, index: Int) -> [CGFloat] {
        [0]
    }
}

final class ScreenshotShelfModel {
    struct Item { let id: UUID; var png: Data; var thumbnail: NSImage }
    private(set) var items: [Item] = []
    let capacity = 6
    let byteLimit = 96 * 1024 * 1024
    @discardableResult func put(id: UUID, png: Data, insert: Bool) -> Bool {
        guard png.count <= byteLimit,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return false }
        let item = Item(id: id, png: png, thumbnail: NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height)))
        if let index = items.firstIndex(where: { $0.id == id }) { items[index] = item }
        else if insert { items.insert(item, at: 0) } else { return false }
        while items.count > capacity || items.reduce(0, { $0 + $1.png.count }) > byteLimit { items.removeLast() }
        return true
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    func clear() { items.removeAll() }
}

enum ScreenshotShelfLayout {
    static func frames(visible: CGRect, screen: CGRect, sizes: [CGSize]) -> [CGRect] {
        guard !sizes.isEmpty, visible.width >= 80, visible.height >= 80 else { return [] }
        let photos = sizes.map(ShelfGeometry.photoSize)
        let widths = photos.map { $0.width + 18 }
        let total = widths.reduce(0, +) + CGFloat(sizes.count - 1) * 24
        let scale = min(1, (visible.width - 24) / total, (visible.height - 50) / 174)
        var x = visible.midX - total * scale / 2
        return photos.enumerated().map { index, photo in
            let size = CGSize(width: widths[index] * scale, height: (photo.height + 28) * scale)
            let y = ShelfGeometry.ropeY(x: x + size.width / 2, screen: screen, top: visible.maxY)
            let pivot = ShelfGeometry.pivot(CGRect(origin: .zero, size: size))
            let rect = CGRect(x: x, y: y - pivot.y, width: size.width, height: size.height)
            x += size.width + 24 * scale
            return rect
        }
    }
    static func frames(visible: CGRect, count: Int) -> [CGRect] {
        frames(visible: visible, screen: visible, sizes: Array(repeating: CGSize(width: 136, height: 104), count: max(0, count)))
    }
}

final class ShelfViewport: NSView {
    let content: NSView
    private let motionAnimationKey = "shelfMotion"
    init(content: NSView, size: CGSize) {
        self.content = content
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true; layer?.masksToBounds = true
        addSubview(content)
    }
    required init?(coder: NSCoder) { nil }

    var presentationMotionOffset: CGFloat? { layer?.presentation()?.sublayerTransform.m42 }

    func setMotionOffset(_ offset: CGFloat) {
        guard let layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.sublayerTransform = CATransform3DMakeTranslation(0, offset, 0)
        CATransaction.commit()
    }

    func animateMotion(offsets: [CGFloat], target: CGFloat, duration: TimeInterval, beginTime: CFTimeInterval) {
        guard let layer, !offsets.isEmpty else { return }
        let animation = CAKeyframeAnimation(keyPath: "sublayerTransform")
        animation.values = offsets.map { NSValue(caTransform3D: CATransform3DMakeTranslation(0, $0, 0)) }
        animation.keyTimes = offsets.indices.map { NSNumber(value: Double($0) / Double(max(1, offsets.count - 1))) }
        animation.calculationMode = .linear
        animation.duration = duration
        animation.beginTime = beginTime
        animation.fillMode = .backwards
        animation.isRemovedOnCompletion = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.sublayerTransform = CATransform3DMakeTranslation(0, target, 0)
        layer.add(animation, forKey: motionAnimationKey)
        CATransaction.commit()
    }

    func removeMotionAnimation(reset: Bool = true) {
        guard let layer else { return }
        layer.removeAnimation(forKey: motionAnimationKey)
        if layer.speed == 0 { resumeMotionAnimation() }
        if reset { setMotionOffset(0) }
    }

    func pauseMotionAnimation() {
        guard let layer, layer.animation(forKey: motionAnimationKey) != nil, layer.speed != 0 else { return }
        layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
    }

    func resumeMotionAnimation() {
        guard let layer, layer.speed == 0 else { return }
        let pausedTime = layer.timeOffset
        layer.speed = 1; layer.timeOffset = 0; layer.beginTime = 0
        let timeSincePause = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        layer.beginTime = timeSincePause
    }
}

private extension NSPanel {
    var shelfContent: NSView? { (contentView as? ShelfViewport)?.content ?? contentView }
}

private final class ShelfPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { shelfContent is ShelfCard }
    override var canBecomeMain: Bool { false }
}

final class ScreenshotShelfController {
    let model = ScreenshotShelfModel()
    private(set) var enabled = false
    private(set) var visible = false
    var onPin: ((NSImage, CGRect?) -> Bool)?
    var onEdit: ((UUID, NSImage) -> Void)?
    func edit(_ id: UUID) {
        guard enabled, let item = model.items.first(where: { $0.id == id }), let image = NSImage(data: item.png) else { return }
        hide()
        onEdit?(id, image)
    }
    private var tombstones: Set<UUID> = []
    private var dragTokens: [UUID: UUID] = [:]
    private var dragRegion = CGRect.zero
    private var dragCancelled = false
    var suspended = false { didSet { if suspended { hide() } } }
    private var panels: [NSPanel] = []
    private var timer: Timer?
    private var localKey: Any?
    private var globalKey: Any?
    private var localMouse: Any?
    private var globalMouse: Any?
    var hasMouseMonitors: Bool { localMouse != nil && globalMouse != nil }
    private var settingsObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var pending: [UUID: DispatchWorkItem] = [:]
    private var revisions: [UUID: UUID] = [:]
    private let queue = DispatchQueue(label: "screenshot.shelf.render", qos: .utility)
    private var hover = ShelfHoverState()
    private var activeScreen: CGRect?
    private var sourceClip = CGRect.zero
    private var keepRegion: CGRect = .zero
    private var closingUntil: TimeInterval?
    private var motionStart: TimeInterval?
    private var motionClosing = false
    private var motionDistance: CGFloat = 180
    private var motionStartOffset: CGFloat = 0
    private var motionInitialVelocity: CGFloat = 0
    private var motionTargetOffset: CGFloat = 0
    private var motionPausedAt: TimeInterval?
    private var restingFrames: [ObjectIdentifier: CGRect] = [:]
    private var closingOrigins: [ObjectIdentifier: CGRect] = [:]
    private var motionHeld = false
    private var mouseWasDown = false
    private var dragging = false
    var windowIDs: Set<CGWindowID> { Set(panels.compactMap { $0.windowNumber > 0 ? CGWindowID(exactly: $0.windowNumber) : nil }) }
    var isMonitoring: Bool { timer != nil }
    func observe(_ store: SettingsStore) {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        setEnabled(store.load().screenshotShelfEnabled)
        settingsObserver = NotificationCenter.default.addObserver(forName: SettingsStore.didSave, object: store, queue: .main) { [weak self] note in
            if let settings = note.userInfo?["settings"] as? AppSettings { self?.setEnabled(settings.screenshotShelfEnabled) }
        }
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if !value { clear(); stopMonitoring(); return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        installMouseMonitors()
        localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.visible {
                if self.dragging { self.dragCancelled = true; return event }
                self.beginClosing(now: ProcessInfo.processInfo.systemUptime, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion); return nil
            }; return event
        }
        // 全局键盘监听受系统权限约束；不为截图架请求新权限。
        globalKey = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self {
                if self.dragging { self.dragCancelled = true } else { self.beginClosing(now: ProcessInfo.processInfo.systemUptime, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.hide() }
    }
    private func stopMonitoring() {
        removeMouseMonitors()
        timer?.invalidate(); timer = nil
        if let localKey { NSEvent.removeMonitor(localKey) }; localKey = nil
        if let globalKey { NSEvent.removeMonitor(globalKey) }; globalKey = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
    }
    deinit {
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        timer?.invalidate()
        if let localKey { NSEvent.removeMonitor(localKey) }
        if let globalKey { NSEvent.removeMonitor(globalKey) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        pending.values.forEach { $0.cancel() }; panels.forEach { $0.orderOut(nil) }
    }
    func add(id: UUID, image: NSImage) {
        guard enabled, !tombstones.contains(id), let png = try? ImageEncoding.pngData(from: image) else { return }
        if model.put(id: id, png: png, insert: true), visible { show() }
    }
    // 主线程取得不可变快照，后台合成，以版本令牌丢弃迟到的结果。
    func update(id: UUID, immediate: Bool = false, snapshot: @escaping () -> ClipboardService.Render?) {
        guard enabled, model.items.contains(where: { $0.id == id }) else { return }
        pending[id]?.cancel()
        let token = UUID(); revisions[id] = token
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled, self.revisions[id] == token, let render = snapshot() else { return }
            self.pending[id] = nil
            self.queue.async { [weak self] in
                guard let data = try? render() else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.enabled, self.revisions[id] == token else { return }
                    if self.model.put(id: id, png: data, insert: false), self.visible { self.show() }
                }
            }
        }
        pending[id] = work
        if immediate { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work) }
    }
    func remove(_ id: UUID) {
        if dragTokens[id] != nil { hide() }
        tombstones.insert(id); dragTokens[id] = nil
        pending.removeValue(forKey: id)?.cancel(); revisions[id] = nil
        model.remove(id); if visible { show() }
    }
    func clear() {
        tombstones.formUnion(model.items.map(\.id)); dragTokens.removeAll()
        pending.values.forEach { $0.cancel() }; pending.removeAll(); revisions.removeAll()
        model.clear(); hide()
    }
    @discardableResult func copy(_ id: UUID, pasteboard: NSPasteboard = .general) -> Bool {
        guard enabled, let item = model.items.first(where: { $0.id == id }) else { return false }
        pasteboard.clearContents(); return pasteboard.setData(item.png, forType: .png)
    }
    func hide() {
        motionStart = nil; motionPausedAt = nil; restingFrames.removeAll(); closingOrigins.removeAll(); motionHeld = false
        removeMouseMonitors()
        dragTokens.removeAll()
        panels.forEach {
            ($0.shelfContent as? ShelfCard)?.invalidateDrag()
            ($0.contentView as? ShelfViewport)?.removeMotionAnimation()
            $0.shelfContent?.layer?.removeAllAnimations()
            ($0.shelfContent as? ShelfCard)?.setFlex(0)
        }
        panels.forEach { $0.orderOut(nil) }; panels.removeAll(); visible = false
        hover.reset(); activeScreen = nil; keepRegion = .zero; closingUntil = nil; dragging = false
    }
    func finishClosing(now: TimeInterval) {
        if let deadline = closingUntil, now >= deadline { hide() }
    }
    func beginClosing(now: TimeInterval, reduceMotion: Bool) {
        guard closingUntil == nil else { return }
        hover.reset()
        if reduceMotion { hide(); return }
        let currentOffset = currentMotionOffset(now: now)
        let currentVelocity = currentMotionVelocity(now: now)
        visible = false; closingUntil = now + ShelfMotion.closingDuration
        motionClosing = true; motionHeld = false
        closingOrigins = Dictionary(uniqueKeysWithValues: panels.map { (ObjectIdentifier($0), $0.frame) })
        panels.forEach { panel in
            panel.ignoresMouseEvents = true
        }
        startMotion(now: now, closing: true, startOffset: currentOffset, initialVelocity: currentVelocity)
    }
    func advanceMotion(now: TimeInterval, reduceMotion: Bool = false) {
        guard let start = motionStart, !motionHeld else { return }
        if reduceMotion && motionClosing { hide(); return }
        let elapsed = CGFloat(max(0, now - start))
        let panelDuration = motionClosing ? ShelfMotion.closingDuration : ShelfMotion.duration
        let t = elapsed / CGFloat(panelDuration)
        let sample = ShelfMotion.sample(t, closing: motionClosing, distance: motionDistance, reduceMotion: reduceMotion)
        for panel in panels {
            guard let viewport = panel.contentView as? ShelfViewport else { continue }
            viewport.removeMotionAnimation(reset: false)
            viewport.setMotionOffset(sample.offset)
            (panel.shelfContent as? ShelfRope)?.flex = sample.flex
            (panel.shelfContent as? ShelfCard)?.setFlex(sample.flex)
        }
        if t >= 1 || reduceMotion {
            completeMotion()
        }
    }

    private func startMotion(now: TimeInterval, closing: Bool, startOffset: CGFloat, initialVelocity: CGFloat) {
        let target = closing ? motionDistance : 0
        let duration = closing ? ShelfMotion.closingDuration : ShelfMotion.duration
        motionStart = now; motionClosing = closing
        motionStartOffset = startOffset; motionInitialVelocity = initialVelocity; motionTargetOffset = target
        motionHeld = false; motionPausedAt = nil
        let offsets = ShelfMotion.keyframes(start: startOffset, target: target, velocity: initialVelocity, duration: duration)
        let flexValues = (0...48).map {
            ShelfMotion.sample(CGFloat($0) / 48, closing: closing, distance: motionDistance, reduceMotion: false).flex
        }
        let beginTime = CACurrentMediaTime() + 0.02
        for panel in panels {
            guard let viewport = panel.contentView as? ShelfViewport else { continue }
            viewport.removeMotionAnimation(reset: false)
            viewport.animateMotion(offsets: offsets, target: target, duration: duration, beginTime: beginTime)
            (panel.shelfContent as? ShelfRope)?.flex = 0
            (panel.shelfContent as? ShelfCard)?.animateFlex(values: flexValues, duration: duration, beginTime: beginTime)
        }
    }

    private func currentMotionOffset(now: TimeInterval) -> CGFloat {
        if let presentation = panels.compactMap({ ($0.contentView as? ShelfViewport)?.presentationMotionOffset }).first {
            return presentation
        }
        guard let start = motionStart else { return 0 }
        return ShelfMotion.offset(target: motionTargetOffset, start: motionStartOffset, velocity: motionInitialVelocity,
                                  seconds: CGFloat(max(0, now - start)))
    }

    private func currentMotionVelocity(now: TimeInterval) -> CGFloat {
        guard let start = motionStart else { return 0 }
        return ShelfMotion.velocity(target: motionTargetOffset, start: motionStartOffset, velocity: motionInitialVelocity,
                                    seconds: CGFloat(max(0, now - start)))
    }

    private func completeMotion() {
        let closing = motionClosing
        motionStart = nil; motionPausedAt = nil; motionHeld = false
        for panel in panels {
            (panel.contentView as? ShelfViewport)?.removeMotionAnimation()
            (panel.shelfContent as? ShelfRope)?.flex = 0
            (panel.shelfContent as? ShelfCard)?.removeFlexAnimation()
        }
        if closing { hide() }
    }

    private func holdMotion() {
        guard !motionHeld else { return }
        motionHeld = true
        guard motionStart != nil else { return }
        motionPausedAt = ProcessInfo.processInfo.systemUptime
        panels.forEach { ($0.contentView as? ShelfViewport)?.pauseMotionAnimation() }
    }

    private func releaseMotion() {
        guard motionHeld else { return }
        motionHeld = false
        if let pausedAt = motionPausedAt {
            let delta = max(0, ProcessInfo.processInfo.systemUptime - pausedAt)
            if let motionStart { self.motionStart = motionStart + delta }
            if let closingUntil { self.closingUntil = closingUntil + delta }
            panels.forEach { ($0.contentView as? ShelfViewport)?.resumeMotionAnimation() }
        }
        motionPausedAt = nil
    }

    private func poll() {
        guard !dragging else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let start = motionStart, !motionHeld {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                if motionClosing { hide() } else { completeMotion() }
            } else if now - start >= (motionClosing ? ShelfMotion.closingDuration : ShelfMotion.duration) {
                completeMotion()
            }
        }
        if closingUntil != nil { finishClosing(now: now); return }
        guard enabled, !suspended, !model.items.isEmpty else { return }
        let point = NSEvent.mouseLocation
        // 透明留白不阻挡下面的应用；不改变顶部停留状态机。
        for panel in panels {
            if let card = panel.shelfContent as? ShelfCard {
                let local = card.convert(panel.convertPoint(fromScreen: point), from: nil)
                panel.ignoresMouseEvents = !card.containsInteraction(local)
            }
        }
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(point) || ShelfGeometry.topHit(point, frame: $0.frame, menuHeight: 4)
        }) else { return }
        if !visible { activeScreen = screen.frame }
        let atTop = ShelfGeometry.topHit(point, frame: screen.frame, menuHeight: NSMenu.menuBarVisible() ? NSStatusBar.system.thickness : 4,
            safeTop: screen.safeAreaInsets.top, left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
        let pressed = NSEvent.pressedMouseButtons != 0
        mouseWasDown = pressed
        let busy = pressed || dragging || NSApp.modalWindow != nil || RunLoop.current.currentMode == .eventTracking
        switch hover.step(now: now, top: atTop, inside: keepRegion.contains(point), visible: visible, busy: busy) {
        case .open: show()
        case .close:
            beginClosing(now: now, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        case .none: break
        }
    }
    func show() {
        guard !dragging else { return }
        guard enabled, !suspended, !model.items.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame == activeScreen }) ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { hide(); return }
        let previous = panels
        let entering = !visible
        motionStart = nil; motionPausedAt = nil; motionHeld = false
        previous.forEach { ($0.contentView as? ShelfViewport)?.removeMotionAnimation() }
        installMouseMonitors()
        panels = []
        closingUntil = nil; activeScreen = screen.frame; hover.reset(block: false)
        let usable = ShelfGeometry.usable(frame: screen.frame, visible: screen.visibleFrame,
            menuHeight: NSStatusBar.system.thickness, safeTop: screen.safeAreaInsets.top)
        sourceClip = usable
        let frames = ScreenshotShelfLayout.frames(visible: usable, screen: screen.frame, sizes: model.items.map { $0.thumbnail.size })
        guard let first = frames.first else { return }
        keepRegion = frames.reduce(first) { $0.union($1) }
        keepRegion = keepRegion.insetBy(dx: -12, dy: -8)
        let rope = makePanel(CGRect(x: screen.frame.minX, y: usable.maxY - 46, width: screen.frame.width, height: 46))
        let ropeView = ShelfRope(frame: CGRect(origin: .zero, size: rope.frame.size))
        rope.contentView = ropeView
        rope.setFrame(CGRect(x: screen.frame.minX, y: usable.maxY - 46, width: screen.frame.width, height: 46), display: true)
        rope.ignoresMouseEvents = true; panels.append(rope)
        for (index, pair) in zip(model.items, frames).enumerated() {
            let (item, layoutFrame) = pair
            // Keep room for the card's hover scale.
            let frame = layoutFrame.insetBy(dx: -8, dy: -8)
            if let panel = previous.first(where: { ($0.shelfContent as? ShelfCard)?.item.id == item.id }),
               let card = panel.shelfContent as? ShelfCard, card.item.png == item.png {
                card.removeFromSuperview()
                panel.contentView = card
                panel.setFrame(frame, display: false)
                card.frame = CGRect(origin: .zero, size: frame.size)
                card.returnRegion = keepRegion
                panels.append(panel); continue
            }
            let panel = makePanel(frame)
            let card = ShelfCard(item: item, frame: CGRect(origin: .zero, size: frame.size), contentInset: 8)
            card.copyAction = { [weak self] in self?.edit(item.id) }
            card.holdMotion = { [weak self] in self?.holdMotion() }
            card.releaseMotion = { [weak self] in
                self?.releaseMotion()
            }
            card.dragStarted = { [weak self] in self?.beginDrag(item.id) }
            card.returnRegion = keepRegion
            card.dragFinished = { [weak self] token, point, operation, cancelled, frame in
                self?.finishDrag(id: item.id, token: token, point: point, operation: operation, cancelled: cancelled, displayFrame: frame)
            }
            panel.contentView = card; panels.append(panel)
            card.configurePivot()
            if !entering { card.animateEntry(index: index) }
        }
        previous.filter { old in !panels.contains(where: { $0 === old }) }.forEach {
            $0.contentView?.layer?.removeAllAnimations(); $0.orderOut(nil)
        }
        restingFrames = Dictionary(uniqueKeysWithValues: panels.map { (ObjectIdentifier($0), $0.frame) })
        for panel in panels {
            guard let content = panel.contentView else { continue }
            let base = panel.frame
            let clipped = base.intersection(usable)
            panel.contentView = nil
            panel.setFrame(clipped, display: false)
            content.frame = CGRect(origin: CGPoint(x: base.minX - clipped.minX, y: base.minY - clipped.minY), size: base.size)
            panel.contentView = ShelfViewport(content: content, size: clipped.size)
            (content as? ShelfCard)?.configurePivot()
        }
        if entering {
            motionDistance = max(42, (frames.map(\.height).max() ?? 0) + 32)
            panels.forEach { ($0.contentView as? ShelfViewport)?.setMotionOffset(0) }
        } else {
            panels.forEach { ($0.contentView as? ShelfViewport)?.setMotionOffset(0) }
        }
        panels.forEach { $0.orderFrontRegardless() }; visible = true
        if entering && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startMotion(now: ProcessInfo.processInfo.systemUptime, closing: false, startOffset: motionDistance, initialVelocity: 0)
        }
    }
    private func makePanel(_ frame: CGRect) -> NSPanel {
        let panel = ShelfPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque = false
        panel.hasShadow = false // 窗口阴影也不能越过源屏边界。
        panel.animationBehavior = .none
        panel.sharingType = .none
        return panel
    }
    private func installMouseMonitors() {
        guard localMouse == nil, enabled, !suspended else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            self?.handleOutsideEvent(type: event.type, point: point)
            return event
        }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleOutsideEvent(type: event.type, point: NSEvent.mouseLocation)
        }
    }
    private func removeMouseMonitors() {
        if let localMouse { NSEvent.removeMonitor(localMouse) }; localMouse = nil
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }; globalMouse = nil
    }
    func handleOutsideEvent(type: NSEvent.EventType, point: CGPoint) {
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type), visible, !dragging else { return }
        let ropeHit = panels.contains { $0.shelfContent is ShelfRope && $0.frame.contains(point) }
        let cardHit = panels.contains { $0.shelfContent is ShelfCard && $0.frame.contains(point) }
        guard !keepRegion.contains(point), !ropeHit, !cardHit else { return }
        hover.reset()
        beginClosing(now: ProcessInfo.processInfo.systemUptime, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        removeMouseMonitors()
    }
    func beginDrag(_ id: UUID) -> UUID? {
        guard enabled, !suspended, !dragging, model.items.contains(where: { $0.id == id }) else { return nil }
        let token = UUID(); dragTokens[id] = token
        dragging = true; dragCancelled = false
        dragRegion = panels.filter { $0.shelfContent is ShelfRope }.reduce(keepRegion) { $0.union($1.frame) }
        return token
    }
    func finishDrag(id: UUID, token: UUID, point: CGPoint, operation: NSDragOperation, cancelled: Bool, displayFrame: CGRect? = nil) {
        guard dragTokens[id] == token else { return }
        dragTokens[id] = nil; dragging = false
        guard enabled, let item = model.items.first(where: { $0.id == id }) else { return }
        if !operation.isEmpty { remove(id); return }
        guard !cancelled, !dragCancelled, !dragRegion.contains(point),
              let image = NSImage(data: item.png), onPin?(image, displayFrame) == true else { return }
        remove(id)
    }
}

final class ShelfRope: NSView {
    var flex: CGFloat = 0 { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let y = bounds.height - 10, sag = min(30, bounds.width * 0.018) - flex * 100
        NSGraphicsContext.saveGraphicsState()
        let outline = NSBezierPath()
        let count = max(2, Int(bounds.width))
        for side in [CGFloat(1), -1] {
            for i in 0...count {
                let f = CGFloat(side > 0 ? i : count - i) / CGFloat(count)
                let thickness = 0.6 + 1.6 * pow(sin(f * .pi), 1.2)
                let point = CGPoint(x: f * bounds.width, y: y - sag * 4 * f * (1 - f) + side * thickness / 2)
                if side > 0 && i == 0 { outline.move(to: point) } else { outline.line(to: point) }
            }
        }
        outline.close()
        NSColor(calibratedRed: 0.61, green: 0.56, blue: 0.46, alpha: 1).setFill(); outline.fill()
        outline.addClip()
        NSColor(calibratedWhite: 0.36, alpha: 0.25).setStroke()
        for x in stride(from: CGFloat(2), to: bounds.width, by: 3) {
            let f = x / bounds.width
            let cy = y - sag * 4 * f * (1 - f)
            let fiber = NSBezierPath(); fiber.move(to: CGPoint(x: x - 0.5, y: cy - 0.8))
            fiber.line(to: CGPoint(x: x + 0.5, y: cy + 0.8)); fiber.lineWidth = 0.4; fiber.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

// 纯本地织纹；独立装饰兄弟视图，永不参与 PNG 数据或照片裁剪。
final class ShelfFabric: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).addClip()
        NSColor(calibratedRed: 0.83, green: 0.80, blue: 0.73, alpha: 1).setFill(); bounds.fill()
        for vertical in [false, true] {
            for v in stride(from: CGFloat(0.5), to: vertical ? bounds.width : bounds.height, by: 1.7) {
                let p = NSBezierPath()
                p.move(to: vertical ? CGPoint(x: v, y: 0) : CGPoint(x: 0, y: v))
                p.line(to: vertical ? CGPoint(x: v, y: bounds.height) : CGPoint(x: bounds.width, y: v))
                NSColor(calibratedWhite: vertical ? 0.35 : 1, alpha: 0.16).setStroke()
                p.lineWidth = 0.45; p.stroke()
            }
        }
        let seam = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 2, yRadius: 2)
        seam.setLineDash([2, 2], count: 2, phase: 0); seam.lineWidth = 0.5
        NSColor(calibratedWhite: 0.36, alpha: 0.45).setStroke(); seam.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// 单个拖动对象同时提供原始 PNG、持久临时 URL 与文件 promise。
final class ShelfPromiseProvider: NSFilePromiseProvider {
    private(set) var png = Data()
    private(set) var fileURL = URL(fileURLWithPath: "/")
    override init() { super.init() }
    init(png: Data, delegate: NSFilePromiseProviderDelegate) throws {
        super.init()
        self.png = png
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotShelfExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(UUID().uuidString + ".png")
        try png.write(to: fileURL, options: .atomic)
        self.fileType = UTType.png.identifier
        self.delegate = delegate
    }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png, .fileURL]
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .png { return png }
        if type == .fileURL { return fileURL.absoluteString }
        return super.pasteboardPropertyList(forType: type)
    }
}

enum ShelfDragGeometry {
    static func frame(point: CGPoint, anchor: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: point.x - anchor.x, y: point.y - anchor.y, width: size.width, height: size.height)
    }
    static func duration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0 : 0.22 }
}

final class ShelfCard: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    let item: ScreenshotShelfModel.Item
    let contentInset: CGFloat
    var decorationBounds: CGRect { bounds.insetBy(dx: contentInset, dy: contentInset) }
    var copyAction: (() -> Void)?
    var holdMotion: (() -> Void)?
    var releaseMotion: (() -> Void)?
    private var restingAngle: CGFloat { ShelfMotion.restingAngle(for: item.id) }
    private let fabric = ShelfFabric(frame: .zero)
    func configurePivot() {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // AppKit 会在布局时重设 backing layer 的 position；保持其标准中心契约。
        // 支点完全编码在 transform 内，不再与 AppKit 竞争 anchorPoint。
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        CATransaction.commit()
    }
    func pivotTransform(angle: CGFloat, scale: CGFloat) -> CATransform3D {
        let p = ShelfGeometry.pivot(decorationBounds)
        let dx = p.x - bounds.midX, dy = p.y - bounds.midY
        var t = CATransform3DScale(CATransform3DMakeRotation(angle, 0, 0, 1), scale, scale, 1)
        t.m41 = dx - dx * t.m11 - dy * t.m21
        t.m42 = dy - dx * t.m12 - dy * t.m22
        return t
    }
    private(set) var flexAngle: CGFloat = 0
    /// 展开/收起时让照片绕夹点轻微滞后摆动；直接落位供测试与降级路径使用。
    func setFlex(_ angle: CGFloat) { setFlex(angle, scale: hoverScale) }
    func setFlex(_ angle: CGFloat, scale: CGFloat) {
        flexAngle = angle
        guard let layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = pivotTransform(angle: restingAngle + angle, scale: scale)
        CATransaction.commit()
        configurePivot()
    }
    func animateFlex(values: [CGFloat], duration: TimeInterval, beginTime: CFTimeInterval) {
        guard let layer, !values.isEmpty else { return }
        layer.removeAnimation(forKey: "shelfFlex")
        if reducesMotion { setFlex(0); return }
        let frames = values.map {
            NSValue(caTransform3D: pivotTransform(angle: restingAngle + $0, scale: hoverScale))
        }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = frames
        animation.keyTimes = frames.indices.map { NSNumber(value: Double($0) / Double(max(1, frames.count - 1))) }
        animation.calculationMode = .linear
        animation.duration = duration
        animation.beginTime = beginTime
        animation.fillMode = .backwards
        animation.isRemovedOnCompletion = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = pivotTransform(angle: restingAngle, scale: hoverScale)
        layer.add(animation, forKey: "shelfFlex")
        CATransaction.commit()
        configurePivot()
    }
    func removeFlexAnimation() {
        layer?.removeAnimation(forKey: "shelfFlex")
        setFlex(0)
    }
    var dragStarted: (() -> UUID?)?
    var dragFinished: ((UUID, CGPoint, NSDragOperation, Bool, CGRect) -> Void)?
    var returnRegion = CGRect.zero
    private var dragAnchor = CGPoint.zero
    private var dragSize = CGSize.zero
    private(set) weak var activeSession: NSDraggingSession?
    func invalidateDrag() {
        dragToken = nil; activeSession?.animatesToStartingPositionsOnCancelOrFail = false
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
        photoView.layer?.removeAllAnimations(); photoView.alphaValue = 1
        layer?.removeAllAnimations()
    }
    private var dragToken: UUID?
    private var escapeMonitor: Any?
    private var escaped = false
    private var activeProvider: ShelfPromiseProvider?
    private var down: NSPoint?
    private var dragged = false
    private(set) var hovered = false
    var reduceMotionOverride: Bool? { didSet { accessibilityChanged() } }
    var reducesMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var hoverScale: CGFloat { hovered && !reducesMotion ? 1.03 : 1 }
    private var frozenTransform = CATransform3DIdentity
    private(set) var liftedPhotoRect = CGRect.zero
    private(set) var controlsVisible = false
    let glass = GlassView(frame: .zero)
    private let photoView = NSImageView(frame: .zero)
    var reduceTransparencyOverride: Bool? { didSet { glass.updateAccessibility(reduceTransparency: reducesTransparency); needsDisplay = true } }
    var reducesTransparency: Bool { reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    var photoRect: CGRect {
        let b = decorationBounds
        let area = CGRect(x: b.minX + 9, y: b.minY + 6, width: max(1, b.width - 18), height: max(1, b.height - 28))
        let size = item.thumbnail.size
        let scale = min(area.width / size.width, area.height / size.height)
        return CGRect(x: area.midX - size.width * scale / 2, y: area.maxY - size.height * scale,
                      width: size.width * scale, height: size.height * scale)
    }
    var rimRect: CGRect { photoRect.insetBy(dx: -5, dy: -5) }
    override var acceptsFirstResponder: Bool { true }
    // 首次按下直接交给卡片，不用激活窗口换取下一次点击。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func becomeFirstResponder() -> Bool { refreshControls(focused: true); return true }
    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.refreshControls() }; return true
    }
    init(item: ScreenshotShelfModel.Item, frame: CGRect, contentInset: CGFloat = 0) {
        self.item = item; self.contentInset = contentInset; super.init(frame: frame)
        wantsLayer = true
        configurePivot()
        addSubview(glass)
        addSubview(fabric)
        photoView.image = item.thumbnail; photoView.imageScaling = .scaleAxesIndependently
        addSubview(photoView)
        layoutDecoration(); refreshControls()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        setAccessibilityLabel("截图：点击编辑，拖至应用导出原像素 PNG，拖至桌面贴图")
        toolTip = "点击编辑 · 拖至应用发送 · 拖至桌面贴图 · Escape 取消拖动"
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }
    @objc private func accessibilityChanged() {
        needsDisplay = true; window?.hasShadow = !reducesTransparency
        guard down == nil else { return }
        if reducesMotion { layer?.removeAllAnimations() }
        applyHover(animated: false)
    }
    override func layout() { super.layout(); layoutDecoration() }
    private func layoutDecoration() {
        configurePivot()
        glass.frame = rimRect
        glass.isHidden = true
        fabric.frame = rimRect
        // 强制限制装饰的光学溢出，照片是独立兄弟层，不受圆角影响。
        glass.layer?.mask = {
            let mask = CAShapeLayer()
            mask.path = CGPath(roundedRect: glass.bounds, cornerWidth: GlassView.cornerRadius, cornerHeight: GlassView.cornerRadius, transform: nil)
            return mask
        }()
        photoView.frame = photoRect
    }
    func refreshControls(focused: Bool? = nil) {
        let responder = window?.firstResponder
        let focus = focused ?? (responder === self)
        controlsVisible = hovered || focus
        needsDisplay = true
    }
    func containsInteraction(_ point: CGPoint) -> Bool {
        photoRect.contains(point) || NSBezierPath(roundedRect: rimRect, xRadius: GlassView.cornerRadius, yRadius: GlassView.cornerRadius).contains(point) || ShelfGeometry.clip(decorationBounds).contains(point) || clipJaw.contains(point)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard containsInteraction(local) else { return nil }
        return self
    }
    func animateEntry(index: Int) {
        layer?.transform = pivotTransform(angle: restingAngle, scale: hoverScale)
        configurePivot()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        guard !hovered else { return }
        hovered = true
        let current = layer?.presentation()?.transform ?? layer?.transform ?? CATransform3DIdentity
        layer?.removeAllAnimations()
        applyHover(animated: false)
        if !reducesMotion {
            let settle = CABasicAnimation(keyPath: "transform")
            settle.fromValue = NSValue(caTransform3D: current)
            settle.toValue = NSValue(caTransform3D: layer?.transform ?? CATransform3DIdentity)
            settle.duration = 0.18; settle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(settle, forKey: "hoverScale")
        }
        refreshControls()
    }
    override func mouseExited(with event: NSEvent) { hovered = false; if down == nil { applyHover(animated: true) }; refreshControls() }
    private func applyHover(animated: Bool) {
        configurePivot()
        // 悬停只做缩放：终止尚未结束的展开摆动，避免鼠标经过时继续抖动。
        layer?.removeAnimation(forKey: "shelfFlex"); flexAngle = 0
        let current = layer?.presentation()?.transform ?? layer?.transform ?? CATransform3DIdentity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.transform = pivotTransform(angle: restingAngle, scale: hoverScale)
        CATransaction.commit()
        configurePivot()
        layer?.removeAnimation(forKey: "hoverScale")
        if animated && !reducesMotion {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: current); animation.toValue = NSValue(caTransform3D: layer!.transform); animation.duration = 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(animation, forKey: "hoverScale")
        }
        glass.layer?.borderWidth = hovered && reducesMotion ? 1 : 0
        glass.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
    func transformedPhotoRect(_ transform: CATransform3D) -> CGRect {
        photoRect.applying(photoTransform(transform))
    }
    private func photoTransform(_ t: CATransform3D) -> CGAffineTransform {
        let p = ShelfGeometry.pivot(decorationBounds)
        return CGAffineTransform(a: t.m11, b: t.m12, c: t.m21, d: t.m22,
            tx: p.x - p.x * t.m11 - p.y * t.m21,
            ty: p.y - p.x * t.m12 - p.y * t.m22)
    }
    var clipJaw: CGRect { CGRect(x: bounds.midX - 3, y: rimRect.maxY - 2, width: 6, height: max(0, ShelfGeometry.clip(decorationBounds).minY - rimRect.maxY + 4)) }
    override func draw(_ dirtyRect: NSRect) {
        let clip = ShelfGeometry.clip(decorationBounds)
        NSColor(white: 0.68, alpha: 1).setFill()
        NSBezierPath(roundedRect: clipJaw, xRadius: 2, yRadius: 2).fill()
        let metal = NSBezierPath(roundedRect: clip, xRadius: 3, yRadius: 3)
        NSGradient(colors: [NSColor(white: 0.48, alpha: 1), NSColor(white: 0.91, alpha: 1), NSColor(white: 0.63, alpha: 1)])?.draw(in: metal, angle: 0)
        NSColor.white.withAlphaComponent(0.8).setFill(); CGRect(x: clip.minX + 3, y: clip.maxY - 2, width: clip.width - 6, height: 1).fill()
    }
    override func mouseDown(with event: NSEvent) {
        holdMotion?()
        frozenTransform = layer?.presentation()?.transform ?? layer?.transform ?? CATransform3DIdentity
        layer?.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.transform = frozenTransform; CATransaction.commit()
        configurePivot()
        liftedPhotoRect = transformedPhotoRect(frozenTransform)
        down = event.locationInWindow; dragged = false
    }
    override func mouseUp(with event: NSEvent) {
        let shouldCopy = down != nil && !dragged
        down = nil
        layer?.transform = CATransform3DIdentity; applyHover(animated: true)
        releaseMotion?()
        if shouldCopy { copyAction?() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let down, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) > 4 else { return }
        guard let provider = try? ShelfPromiseProvider(png: item.png, delegate: self), let token = dragStarted?() else { return }
        dragged = true; dragToken = token; escaped = false; activeProvider = provider
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.escaped = true
                self?.activeSession?.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }; return event
        }
        let dragging = NSDraggingItem(pasteboardWriter: provider)
        let grab = convert(down, from: nil)
        dragAnchor = CGPoint(x: grab.x - liftedPhotoRect.minX, y: grab.y - liftedPhotoRect.minY)
        dragSize = liftedPhotoRect.size
        // 抓取点属于首次按下，阈值内的移动也应体现在首次拖图位置。
        let current = convert(event.locationInWindow, from: nil)
        let dragImage = NSImage(size: dragSize, flipped: false) { [self] _ in
            let transform = NSAffineTransform()
            var affine = photoTransform(frozenTransform)
            affine.tx -= liftedPhotoRect.minX; affine.ty -= liftedPhotoRect.minY
            transform.transformStruct = NSAffineTransformStruct(m11: affine.a, m12: affine.b, m21: affine.c, m22: affine.d, tX: affine.tx, tY: affine.ty)
            NSGraphicsContext.saveGraphicsState(); transform.concat()
            item.thumbnail.draw(in: photoRect)
            NSGraphicsContext.restoreGraphicsState(); return true
        }
        dragging.setDraggingFrame(ShelfDragGeometry.frame(point: current, anchor: dragAnchor, size: dragSize), contents: dragImage)
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        activeSession = session
        session.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        layer?.removeAllAnimations()
        // 原生拖图接管照片；仅淡出源照片，夹子和外框仍留在架上。
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            photoView.animator().alphaValue = 0
        }
    }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        session.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && (escaped || returnRegion.contains(screenPoint))
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
        down = nil
        activeSession = nil
        releaseMotion?()
        layer?.transform = CATransform3DIdentity; applyHover(animated: true)
        photoView.layer?.removeAllAnimations(); photoView.alphaValue = 1
        let frame = ShelfDragGeometry.frame(point: screenPoint, anchor: dragAnchor, size: dragSize)
        if let token = dragToken { dragToken = nil; dragFinished?(token, screenPoint, operation, escaped, frame) }
        // 文件不在完成回调中删除，接收方可能尚未异步读取。
        // promise 的 delegate 为弱引用；保留源卡片直到写入队列完成。
        if let provider = activeProvider {
            provider.userInfo = self
        }
        activeProvider = nil
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "截图-\(item.id.uuidString.prefix(8)).png" }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try item.png.write(to: url, options: .atomic); completionHandler(nil) } catch { completionHandler(error) }
    }
}
