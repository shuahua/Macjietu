import AppKit
import QuartzCore

/// 只动画展示层，不改变 frame、命中区域、target/action 或 AppKit 的跟踪循环。
@MainActor
final class GlassButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private(set) var hovered = false
    private(set) var focused = false
    private(set) var feedbackLevel: Float = 0
    private let feedback = CALayer()
    var reduceMotionOverride: Bool?
    var reduceTransparencyOverride: Bool?
    private(set) var usesSidebarSurface = false
    private(set) var usesMomentaryActionSurface = false

    /// 仅供截图工具栏的四个命令使用；共享 toggle/sidebar 不改变语义。
    func useMomentaryActionSurface() {
        let originalTarget = target
        let originalAction = action
        let actionCell = MomentaryActionButtonCell(imageCell: image)
        actionCell.imagePosition = imagePosition
        cell = actionCell
        target = originalTarget
        action = originalAction
        setButtonType(.momentaryPushIn)
        actionCell.highlightsBy = [.pushInCellMask]
        actionCell.showsStateBy = []
        usesMomentaryActionSurface = true
        state = .off
        refreshFeedback()
    }

    private func finishMomentaryAction() {
        guard usesMomentaryActionSurface else { return }
        state = .off
        highlight(false)
        refreshFeedback()
    }

    func useSidebarSurface() {
        let originalTarget = target
        let originalAction = action
        let originalTag = tag
        let originalState = state
        let sidebarCell = SidebarButtonCell(textCell: title)
        sidebarCell.font = font
        sidebarCell.alignment = alignment
        sidebarCell.image = image
        sidebarCell.imagePosition = imagePosition
        cell = sidebarCell
        target = originalTarget
        action = originalAction
        tag = originalTag
        setButtonType(.toggle)
        state = originalState
        sidebarCell.highlightsBy = []
        sidebarCell.showsStateBy = []
        focusRingType = .none
        usesSidebarSurface = true
        feedback.isHidden = true
        refreshFeedback()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        feedback.cornerRadius = 7
        feedback.name = "glassFeedbackSurface"
        feedback.opacity = 0
        layer?.addSublayer(feedback)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshFeedback),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        feedback.frame = bounds.insetBy(dx: 2, dy: 2)
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ value: Bool) { hovered = value; refreshFeedback() }
    override func highlight(_ flag: Bool) { super.highlight(flag); refreshFeedback() }
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        // 在 action 打开面板/关闭编辑器之前清理，而不是异步等待下一轮运行循环。
        finishMomentaryAction()
        let result = super.sendAction(action, to: target)
        finishMomentaryAction()
        refreshFeedback()
        return result
    }
    override func performClick(_ sender: Any?) { super.performClick(sender); finishMomentaryAction(); refreshFeedback() }
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event); finishMomentaryAction(); refreshFeedback() }
    override var state: NSControl.StateValue { didSet { refreshFeedback() } }
    override var isEnabled: Bool { didSet { refreshFeedback() } }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        focused = accepted
        refreshFeedback()
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focused = false }
        refreshFeedback()
        return accepted
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFeedback()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovered = false; focused = false; feedback.removeAllAnimations() }
        refreshFeedback()
    }
    @objc func refreshFeedback() {
        needsDisplay = true
        let reduced = reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let opaque = reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let active = state != .off
        let level: Float = !isEnabled ? 0 : (usesMomentaryActionSurface
            ? (isHighlighted ? 0.22 : 0)
            : (isHighlighted ? 0.22 : (focused ? 0.18 : (active ? 0.14 : (hovered ? 0.08 : 0)))))
        let previous = feedback.presentation()?.opacity ?? feedback.opacity
        feedback.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        feedback.backgroundColor = NSColor.controlAccentColor.cgColor
        feedback.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        feedback.borderWidth = focused || (opaque && level > 0) ? 2 : 0
        feedback.opacity = level
        CATransaction.commit()
        feedbackLevel = level
        if !usesMomentaryActionSurface && !usesSidebarSurface && !reduced && previous != level && window != nil {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = previous
            animation.toValue = level
            animation.duration = isHighlighted ? 0.08 : 0.16
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            feedback.add(animation, forKey: "glassFeedback")
        }
    }
    var hasFeedbackAnimation: Bool { feedback.animation(forKey: "glassFeedback") != nil }
}

/// 不绘制原生 rounded bezel 的 accent/default/focus 填充；焦点只有细描边。
/// NSButtonCell 的原生 tracking、取消和键盘 action 路径保持不变。
private final class MomentaryActionButtonCell: NSButtonCell {
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        super.highlight(flag, withFrame: cellFrame, in: controlView)
        (controlView as? GlassButton)?.refreshFeedback()
    }
    override var isHighlighted: Bool {
        didSet { (controlView as? GlassButton)?.refreshFeedback() }
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor.controlColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: cellFrame.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
        if let button = controlView as? GlassButton, button.focused && button.isEnabled {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            ring.lineWidth = 1
            ring.stroke()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }
}

/// 唯一底形：不调用 native bezel，也不叠加 GlassButton 的反馈层。
/// 所有状态共用 bounds 和内文布局，系统 cell 只负责 label/icon。
private final class SidebarButtonCell: NSButtonCell {
    override var isHighlighted: Bool {
        didSet { (controlView as? GlassButton)?.refreshFeedback() }
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let button = controlView as? GlassButton else { return }
        let opaque = button.reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let level: CGFloat = !button.isEnabled ? 0 : (isHighlighted ? 0.22 : (state != .off ? 0.14 : (button.hovered ? 0.08 : 0)))
        if level > 0 {
            let color = NSColor.controlAccentColor.withAlphaComponent(level)
            (opaque ? color.blended(withFraction: 1 - level, of: .controlBackgroundColor)?.withAlphaComponent(1) ?? NSColor.controlBackgroundColor : color).setFill()
            NSBezierPath(roundedRect: cellFrame, xRadius: 7, yRadius: 7).fill()
        }
        if button.focused && button.isEnabled {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2
            ring.stroke()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }
}

@MainActor
enum GlassMotion {
    /// 模型 alpha 始终为 1；关闭无需等待 completion，也不会迟到重新显示窗口。
    static func reveal(_ view: NSView?, reduceMotion: Bool? = nil) {
        guard let view else { return }
        view.wantsLayer = true
        view.layer?.removeAnimation(forKey: "glassReveal")
        guard !(reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.layer?.add(animation, forKey: "glassReveal")
    }
}
