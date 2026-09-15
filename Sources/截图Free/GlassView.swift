import AppKit

/// 只承载控制 UI；画布和播放器必须作为独立前景视图，不能放在效果层后面。
@MainActor
final class GlassView: NSView {
    static let cornerRadius: CGFloat = 14
    static let normalTintOpacity: CGFloat = 0.06
    // WindowServer 的透明像素命中先于 NSView.hitTest。系统玻璃的合成材质
    // 不能替代窗口 backing 的非零 alpha；只填充功能面板，不填充外部透明根层。
    static let interactionBackingOpacity: CGFloat = 0.02
    let effectView: NSVisualEffectView = PassiveVisualEffectView()
    enum Backend: Equatable { case native, standard, opaque }
    private(set) var backend: Backend = .standard
    let controlsHost = GlassContentView()
    private var nativeSurface: NSView?
    private var nativeContainer: NSView?
    private var ready = false
    var usesStandardContentBackground = false { didSet { accessibilityChanged() } }
    var forceFallback = false { didSet { accessibilityChanged() } }
    /// 仅用于已有透明外边距的嵌入式浮动工具栏；原生后端不叠加人工阴影。
    var castsSoftShadow = false { didSet { updateShadow() } }
    static let shadowPadding: CGFloat = 32
    var dragsWindowOnBackground = false
    override var mouseDownCanMoveWindow: Bool { dragsWindowOnBackground }

    override func mouseDown(with event: NSEvent) {
        if dragsWindowOnBackground { window?.performDrag(with: event) }
        else { super.mouseDown(with: event) }
    }
    private let tintView = GlassTintView()
    private(set) var reducesTransparency = false

    override var allowsVibrancy: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.interactionBackingOpacity).cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0
        layer?.borderColor = nil
        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        // 浮动控制窗口采用 HUD 材质，避免 popover 再叠高浓度遮罩显得过实。
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = Self.cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0
        effectView.layer?.borderColor = nil
        addSubview(effectView)
        tintView.frame = bounds
        tintView.autoresizingMask = [.width, .height]
        effectView.addSubview(tintView)
        controlsHost.autoresizingMask = [.width, .height]
        super.addSubview(controlsHost)
        // 编译器门控对应 Xcode 26 工具链；独立开关供旧 SDK 配对及兼容构建验证。
        #if compiler(>=6.2) && !LIQUID_GLASS_FALLBACK
        if #available(macOS 26.0, *) {
            let surface = NSGlassEffectView(frame: bounds)
            surface.style = .regular
            surface.cornerRadius = Self.cornerRadius
            let container = NSGlassEffectContainerView(frame: bounds)
            container.spacing = 0
            let group = NSView(frame: bounds)
            group.autoresizingMask = [.width, .height]
            surface.autoresizingMask = [.width, .height]
            group.addSubview(surface)
            container.contentView = group
            container.autoresizingMask = [.width, .height]
            super.addSubview(container)
            nativeSurface = surface
            nativeContainer = container
        }
        #endif
        ready = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        accessibilityChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func accessibilityChanged() {
        updateAccessibility(reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layer?.removeAnimation(forKey: "glassReveal")
        }
    }

    // 独立入口使测试无需改变用户的系统辅助功能偏好。
    func updateAccessibility(reduceTransparency: Bool) {
        reducesTransparency = reduceTransparency
        tintView.opacity = reduceTransparency || usesStandardContentBackground ? 1 : Self.normalTintOpacity
        effectView.state = reduceTransparency ? .inactive : .active
        let useNative = nativeSurface != nil && !forceFallback && !reduceTransparency && !usesStandardContentBackground
        backend = reduceTransparency ? .opaque : (useNative ? .native : .standard)
        #if compiler(>=6.2) && !LIQUID_GLASS_FALLBACK
        if #available(macOS 26.0, *), let surface = nativeSurface as? NSGlassEffectView {
            if useNative {
                if surface.contentView !== controlsHost {
                    controlsHost.removeFromSuperview()
                    surface.contentView = controlsHost
                }
            } else if controlsHost.superview !== self {
                // 先解除原生内容所属关系，再恢复普通 NSView 的布局契约。
                controlsHost.removeFromSuperview()
                surface.contentView = nil
                super.addSubview(controlsHost)
            }
        }
        #endif
        controlsHost.frame = useNative ? (nativeSurface?.bounds ?? bounds) : bounds
        // 原生 surface 会改变此属性；fallback 必须恢复，否则布局后 host 可归零宽。
        if !useNative { controlsHost.translatesAutoresizingMaskIntoConstraints = true }
        controlsHost.autoresizingMask = [.width, .height]
        nativeContainer?.isHidden = !useNative
        effectView.isHidden = useNative
        // 不裁掉系统玻璃边缘光学效果；媒体圆角由独立显示层负责。
        layer?.masksToBounds = !useNative
        updateShadow()
    }

    private func updateShadow() {
        layer?.masksToBounds = !castsSoftShadow && backend != .native
        layer?.shadowOpacity = castsSoftShadow && backend != .native ? 0.12 : 0
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowPath = castsSoftShadow && backend != .native
            ? CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil) : nil
    }

    override func layout() {
        super.layout()
        updateShadow()
    }

    override func addSubview(_ view: NSView) {
        if ready { controlsHost.addSubview(view) } else { super.addSubview(view) }
    }

    override func addSubview(_ view: NSView, positioned place: NSWindow.OrderingMode, relativeTo otherView: NSView?) {
        if ready && view !== controlsHost && view !== nativeContainer {
            controlsHost.addSubview(view, positioned: place, relativeTo: otherView)
        } else {
            super.addSubview(view, positioned: place, relativeTo: otherView)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // NSView.hitTest 输入属于接收视图的 superview，而非接收者本地坐标。
        // 原生 contentView 可被 AppKit 包装；只使用公开 superview/convert，不识别私有类。
        guard !isHidden, alphaValue > 0,
              bounds.contains(convert(point, from: superview)) else { return nil }
        let controlPoint = controlsHost.superview?.convert(point, from: superview) ?? point
        if let controlHit = controlsHost.hitTest(controlPoint) {
            return controlHit
        }
        let hit = super.hitTest(point)
        guard let hit else { return nil }
        if hit === controlsHost || hit === nativeSurface || hit === nativeContainer ||
            (hit !== self && !hit.isDescendant(of: controlsHost)) { return self }
        return hit
    }

    var tintOpacity: CGFloat { tintView.opacity }

    static func prepareWindow(_ window: NSWindow) {
        // 不改变层级、焦点、Space、激活或关闭行为。
        window.isOpaque = false
        window.backgroundColor = .clear
        if window.styleMask.contains(.titled) { window.titlebarAppearsTransparent = true }
    }
}

final class GlassContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// 材质和遮罩只绘制，不抢占标题空白或前景控件的鼠标命中。
private final class PassiveVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class GlassTintView: NSView {
    var opacity: CGFloat = GlassView.normalTintOpacity { didSet { needsDisplay = true } }
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: GlassView.cornerRadius,
                     yRadius: GlassView.cornerRadius).addClip()
        NSColor.windowBackgroundColor.withAlphaComponent(opacity).setFill()
        bounds.fill()
    }
}
