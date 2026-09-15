import AppKit

enum AnnotationTool: String {
    case none = ""
    case pen = "画笔"
    case text = "文字"
    case eraser = "橡皮"
    case rectangle = "矩形"
    case oval = "圆形"
    case line = "直线"
    case arrow = "箭头"
    case mosaic = "马赛克"
}

enum AnnotationShape {
    case pen([CGPoint], NSColor, CGFloat)
    case text(String, CGPoint, NSColor, CGFloat, String, TextWeight, Bool)
    case rectangle(CGRect, NSColor, CGFloat)
    case oval(CGRect, NSColor, CGFloat)
    case line(CGPoint, CGPoint, NSColor, CGFloat)
    case arrow(CGPoint, CGPoint, NSColor, CGFloat)
    case mosaic(CGRect)
}

enum TextWeight: Int {
    case regular
    case medium
    case semibold
    case bold

    var fontWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

private final class AnnotationOptionsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class AnnotationEditorWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// 图片展示装饰层：圆角只作用于显示层，导出仍由 AnnotationCanvasView 生成原始像素。
final class MediaDisplayView: NSView {
    static let cornerRadius: CGFloat = 11

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
        subviews.first?.layer?.cornerRadius = Self.cornerRadius
        subviews.first?.layer?.masksToBounds = true
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
    }
}

@MainActor
final class AnnotationEditorController: NSObject {
    private let minimumToolbarWidth: CGFloat = 560
    private let horizontalPadding = GlassView.shadowPadding
    private let verticalPadding = GlassView.shadowPadding
    private let topSafePadding: CGFloat = 36
    var onComplete: ((NSImage) -> Void)?
    var onCancel: (() -> Void)?
    var onCopy: ((NSImage) -> Void)?
    var onSave: ((NSImage) -> Bool)?
    var onPin: ((NSImage) -> Void)?
    var onClose: (() -> Void)?

    private let image: NSImage
    private let exportScale: CGFloat
    private let allowsZoom: Bool
    private var window: NSWindow?
    private var contentView: NSView?
    private var canvasView: AnnotationCanvasView?
    private var scrollView: NSScrollView?
    private var toolbarView: GlassView?
    private var optionsWindow: NSPanel?
    private var resizeHandleView: ResizeHandleView?
    private var baseCanvasSize: CGSize = .zero
    private var toolControl: NSSegmentedControl?
    private var shapePopup: NSPopUpButton?
    private var selectedShapeTool: AnnotationTool = .rectangle
    private var isShapeToolActive = false
    private var strokeSlider: NSSlider?
    private var strokeValueLabel: NSTextField?
    private var colorWells: [NSButton] = []
    private var customColorButton: NSButton?
    private var ownsColorPanel = false
    private var textFontName = "Helvetica Neue"
    private var textWeight: TextWeight = .semibold
    private var textUnderline = false
    private var zoomSlider: NSSlider?
    private var zoomValueLabel: NSTextField?
    private var zoomScale: CGFloat = 1
    private var showsZoomControls = false
    private let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white]
    private var didClose = false

    init(image: NSImage, exportScale: CGFloat = 1, allowsZoom: Bool = false) {
        self.image = image
        self.exportScale = exportScale
        self.allowsZoom = allowsZoom
        super.init()
    }

    func show() {
        if allowsZoom {
            showLongScreenshotEditor()
        } else {
            showStandardEditor()
        }
    }

    private func showLongScreenshotEditor() {
        let horizontalPadding = self.horizontalPadding
        let verticalPadding = self.verticalPadding
        let topSafePadding: CGFloat = 36
        let toolbarHeight: CGFloat = 62
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let canvasSize = longScreenshotCanvasSize(for: image.size, screenFrame: screenFrame, horizontalPadding: horizontalPadding)
        baseCanvasSize = canvasSize
        let toolbarSize = CGSize(width: minimumToolbarWidth, height: toolbarHeight)
        let viewportSize = viewportSize(for: canvasSize, toolbarHeight: toolbarHeight, screenFrame: screenFrame)
        let contentSize = CGSize(
            width: max(viewportSize.width, toolbarSize.width) + horizontalPadding * 2,
            height: viewportSize.height + toolbarSize.height + verticalPadding * 3 + topSafePadding
        )
        let contentView = NSView(frame: CGRect(origin: .zero, size: contentSize))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        let canvasFrame = CGRect(
            x: (contentSize.width - viewportSize.width) / 2,
            y: verticalPadding * 2 + toolbarHeight,
            width: viewportSize.width,
            height: viewportSize.height
        )
        let canvas = AnnotationCanvasView(frame: CGRect(origin: .zero, size: canvasSize), image: image)
        let display = MediaDisplayView(frame: canvasFrame)
        let scrollView = NSScrollView(frame: display.bounds)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = canvas
        scrollView.autohidesScrollers = false
        scrollView.allowsMagnification = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = MediaDisplayView.cornerRadius
        scrollView.layer?.masksToBounds = true
        display.addSubview(scrollView)
        contentView.addSubview(display)
        let resizeHandle = ResizeHandleView(frame: resizeHandleFrame(for: canvasFrame))
        resizeHandle.onResize = { [weak self] delta in self?.resizeLongScreenshot(by: delta) }
        contentView.addSubview(resizeHandle)
        self.contentView = contentView
        canvasView = canvas
        self.scrollView = scrollView
        resizeHandleView = resizeHandle

        let toolbarOrigin = CGPoint(x: (contentSize.width - toolbarSize.width) / 2, y: verticalPadding)
        addStandardToolbar(to: contentView, toolbarSize: toolbarSize, origin: toolbarOrigin)

        let rect = CGRect(x: screenFrame.midX - contentSize.width / 2, y: screenFrame.midY - contentSize.height / 2, width: contentSize.width, height: contentSize.height)
        let window = makeEditorWindow(rect: rect, contentView: contentView)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
    }

    private func showStandardEditor() {
        let horizontalPadding = self.horizontalPadding
        let verticalPadding = self.verticalPadding
        let topSafePadding: CGFloat = 36
        let toolbarHeight: CGFloat = 62
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let canvasSize = canvasSize(for: image.size, screenFrame: screenFrame, toolbarHeight: toolbarHeight, horizontalPadding: horizontalPadding, verticalPadding: verticalPadding)
        baseCanvasSize = canvasSize
        let toolbarSize = CGSize(width: minimumToolbarWidth, height: toolbarHeight)
        let contentSize = CGSize(
            width: max(canvasSize.width, toolbarSize.width) + horizontalPadding * 2,
            height: canvasSize.height + toolbarSize.height + verticalPadding * 3 + topSafePadding
        )
        let contentView = NSView(frame: CGRect(origin: .zero, size: contentSize))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        let canvasFrame = CGRect(
            x: (contentSize.width - canvasSize.width) / 2,
            y: verticalPadding * 2 + toolbarHeight,
            width: canvasSize.width,
            height: canvasSize.height
        )
        let canvas = AnnotationCanvasView(frame: CGRect(origin: .zero, size: canvasFrame.size), image: image)
        let display = MediaDisplayView(frame: canvasFrame)
        display.addSubview(canvas)
        contentView.addSubview(display)
        self.contentView = contentView
        canvasView = canvas
        scrollView = nil

        let toolbarOrigin = CGPoint(x: (contentSize.width - toolbarSize.width) / 2, y: verticalPadding)
        addStandardToolbar(to: contentView, toolbarSize: toolbarSize, origin: toolbarOrigin)

        let rect = CGRect(x: screenFrame.midX - contentSize.width / 2, y: screenFrame.midY - contentSize.height / 2, width: contentSize.width, height: contentSize.height)
        let window = makeEditorWindow(rect: rect, contentView: contentView)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
    }

    private func makeEditorWindow(rect: CGRect, contentView: NSView) -> AnnotationEditorWindow {
        let window = AnnotationEditorWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.onEscape = { [weak self] in
            guard let self else { return }
            if self.canvasView?.commitTextEditing() == true { return }
            self.closeWindow()
        }
        window.title = "截图编辑"
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = contentView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        // 透明根容器中有互相分离的画布和工具栏，不生成整窗复合阴影。
        window.hasShadow = false
        return window
    }

    @objc private func selectPen() {
        deactivateShapeTool()
        canvasView?.tool = .pen
        showPenOptions()
    }

    @objc private func selectText() {
        deactivateShapeTool()
        canvasView?.tool = .text
        canvasView?.onTextSelectionChanged = { [weak self] in
            guard let self, let canvas = self.canvasView else { return }
            self.textFontName = canvas.textFontName
            self.textWeight = canvas.textWeight
            self.textUnderline = canvas.textUnderline
            self.showTextOptions()
        }
        showTextOptions()
    }

    @objc private func selectEraser() {
        deactivateShapeTool()
        canvasView?.tool = .eraser
        closeOptionsWindow()
    }

    @objc private func selectRectangle() {
        selectShape(.rectangle, index: 0)
    }

    @objc private func selectOval() {
        selectShape(.oval, index: 1)
    }

    @objc private func selectLine() {
        selectShape(.line, index: 2)
    }

    @objc private func selectArrow() {
        selectShape(.arrow, index: 3)
    }

    private func selectShape(_ tool: AnnotationTool, index: Int) {
        if isShapeToolActive && canvasView?.tool == tool {
            deactivateShapeTool()
            closeOptionsWindow()
            return
        }
        selectedShapeTool = tool
        isShapeToolActive = true
        toolControl?.selectedSegment = -1
        canvasView?.tool = tool
        showPenOptions()
        updateShapePopup(selectedIndex: index)
    }

    @objc private func selectMosaic() {
        deactivateShapeTool()
        canvasView?.tool = .mosaic
        closeOptionsWindow()
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        if canvasView?.tool == tool(for: sender.selectedSegment) {
            canvasView?.tool = .none
            deactivateShapeTool()
            closeOptionsWindow()
            sender.selectedSegment = -1
            return
        }

        switch sender.selectedSegment {
        case -1:
            canvasView?.tool = .none
            deactivateShapeTool()
            closeOptionsWindow()
        case 1:
            selectEraser()
        case 2:
            selectMosaic()
        case 3:
            selectText()
        default:
            selectPen()
        }
    }

    private func tool(for segment: Int) -> AnnotationTool {
        switch segment {
        case 0: return .pen
        case 1: return .eraser
        case 2: return .mosaic
        case 3: return .text
        default: return .none
        }
    }

    @objc private func shapePopupChanged(_ sender: NSPopUpButton) {
        let selectedTool = shapeTool(for: sender.indexOfSelectedItem)
        if isShapeToolActive && selectedTool == selectedShapeTool {
            deactivateShapeTool()
            closeOptionsWindow()
            return
        }

        switch selectedTool {
        case .oval: selectOval()
        case .line: selectLine()
        case .arrow: selectArrow()
        default: selectRectangle()
        }
    }

    private func updateShapePopup(selectedIndex: Int) {
        shapePopup?.selectItem(at: selectedIndex)
        shapePopup?.toolTip = shapePopup?.selectedItem?.title
        updateShapePopupAppearance()
    }

    private func shapeTool(for selectedIndex: Int) -> AnnotationTool {
        switch selectedIndex {
        case 1: return .oval
        case 2: return .line
        case 3: return .arrow
        default: return .rectangle
        }
    }

    private func deactivateShapeTool() {
        isShapeToolActive = false
        if canvasView?.tool == selectedShapeTool {
            canvasView?.tool = .none
        }
        updateShapePopupAppearance()
    }

    private func updateShapePopupAppearance() {
        guard let shapePopup else { return }
        shapePopup.wantsLayer = true
        shapePopup.layer?.cornerRadius = 6
        shapePopup.layer?.borderWidth = isShapeToolActive ? 2 : 0
        shapePopup.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    @objc private func clearAnnotations() {
        canvasView?.clear()
    }

    @objc private func strokeSliderChanged(_ sender: NSSlider) {
        let width = CGFloat(sender.doubleValue)
        if sender.tag == 1 {
            canvasView?.textPointSize = width
            strokeValueLabel?.stringValue = "\(Int(width.rounded())) pt"
            return
        }
        canvasView?.strokeWidth = width
        strokeValueLabel?.stringValue = "\(Int(width.rounded())) px"
    }

    @objc private func zoomSliderChanged(_ sender: NSSlider) {
        guard showsZoomControls else { return }
        zoomScale = CGFloat(sender.doubleValue)
        applyZoomScale()
        zoomValueLabel?.stringValue = String(format: "%.1fx", zoomScale)
    }

    @objc private func colorSelected(_ sender: NSButton) {
        let index = sender.tag
        guard colors.indices.contains(index) else { return }
        canvasView?.strokeColor = colors[index]
        colorWells.forEach {
            let isSelected = $0 === sender
            $0.state = isSelected ? .on : .off
            $0.layer?.borderWidth = isSelected ? 3 : 1
            $0.layer?.borderColor = NSColor.white.withAlphaComponent(isSelected ? 0.95 : 0.35).cgColor
        }
        customColorButton?.layer?.borderWidth = 1
        customColorButton?.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
    }

    @objc private func showColorPanel() {
        ownsColorPanel = true
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.color = canvasView?.strokeColor ?? .systemRed
        panel.orderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        canvasView?.strokeColor = sender.color
        customColorButton?.layer?.backgroundColor = sender.color.cgColor
        customColorButton?.layer?.borderWidth = 3
        customColorButton?.layer?.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        colorWells.forEach {
            $0.state = .off
            $0.layer?.borderWidth = 1
            $0.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        }
    }

    @objc private func textFontChanged(_ sender: NSPopUpButton) {
        textFontName = sender.titleOfSelectedItem ?? textFontName
        canvasView?.textFontName = textFontName
    }

    @objc private func textWeightChanged(_ sender: NSPopUpButton) {
        textWeight = TextWeight(rawValue: sender.indexOfSelectedItem) ?? .semibold
        canvasView?.textWeight = textWeight
    }

    @objc private func textUnderlineChanged(_ sender: NSButton) {
        textUnderline = sender.state == .on
        canvasView?.textUnderline = textUnderline
    }

    private func showPenOptions() {
        showOptionsWindow(size: CGSize(width: 336, height: 86)) { [weak self] contentView in
            guard let self else { return }
            self.addStrokeControls(to: contentView, y: 48)
            self.addColorControls(to: contentView, y: 14)
        }
    }

    private func showTextOptions() {
        canvasView?.textFontName = textFontName
        canvasView?.textWeight = textWeight
        canvasView?.textUnderline = textUnderline
        showOptionsWindow(size: CGSize(width: 420, height: 126)) { [weak self] contentView in
            guard let self else { return }
            let label = self.addOptionLabel("字体", x: 16, y: 92, width: 36, to: contentView)
            let fontPopup = NSPopUpButton(frame: CGRect(x: label.frame.maxX + 8, y: 87, width: 154, height: 28), pullsDown: false)
            let fontNames = ["Helvetica Neue", "PingFang SC", "Songti SC", "Kaiti SC", "Menlo", "Arial"]
            fontNames.forEach { fontPopup.addItem(withTitle: $0) }
            if let index = fontNames.firstIndex(of: self.textFontName) { fontPopup.selectItem(at: index) }
            fontPopup.target = self
            fontPopup.action = #selector(self.textFontChanged(_:))
            contentView.addSubview(fontPopup)

            let weightPopup = NSPopUpButton(frame: CGRect(x: fontPopup.frame.maxX + 10, y: 87, width: 92, height: 28), pullsDown: false)
            ["常规", "中等", "半粗", "粗体"].forEach { weightPopup.addItem(withTitle: $0) }
            weightPopup.selectItem(at: self.textWeight.rawValue)
            weightPopup.target = self
            weightPopup.action = #selector(self.textWeightChanged(_:))
            contentView.addSubview(weightPopup)

            let underline = GlassButton(checkboxWithTitle: "下划线", target: self, action: #selector(self.textUnderlineChanged(_:)))
            underline.frame = CGRect(x: weightPopup.frame.maxX + 10, y: 90, width: 74, height: 22)
            underline.state = self.textUnderline ? .on : .off
            contentView.addSubview(underline)

            self.addStrokeControls(to: contentView, y: 52, label: "字号")
            self.addColorControls(to: contentView, y: 16)
        }
    }

    private func showOptionsWindow(size: CGSize, build: (NSView) -> Void) {
        closeOptionsWindow()
        guard let window else { return }
        let panel = Self.makeOptionsPanel(size: size)
        guard let contentView = panel.contentView as? GlassView else { return }
        build(contentView.controlsHost)
        let frame = window.frame
        let visible = window.screen?.visibleFrame ?? frame
        // 以主窗口可见内容边缘定位；shadowPadding 只服务于外框，不参与菜单间距。
        let gap: CGFloat = 7
        let preferredY = frame.minY - size.height - gap
        let y = preferredY >= visible.minY ? preferredY : frame.maxY + gap
        panel.setFrameOrigin(CGPoint(
            x: max(visible.minX, min(frame.midX - size.width / 2, visible.maxX - size.width)),
            y: max(visible.minY, min(y, visible.maxY - size.height))
        ))
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        optionsWindow = panel
        GlassMotion.reveal(contentView)
    }

    static func makeOptionsPanel(size: CGSize) -> NSPanel {
        let bounds = CGRect(origin: .zero, size: size)
        let panel = AnnotationOptionsPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "标注参数"
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        panel.contentView = GlassView(frame: bounds)
        return panel
    }

    private func closeOptionsWindow() {
        if ownsColorPanel {
            NSColorPanel.shared.orderOut(nil)
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
            ownsColorPanel = false
        }
        if let optionsWindow {
            optionsWindow.parent?.removeChildWindow(optionsWindow)
        }
        optionsWindow?.orderOut(nil)
        optionsWindow?.contentView = nil
        optionsWindow = nil
        strokeSlider = nil
        strokeValueLabel = nil
        colorWells.removeAll()
        customColorButton = nil
    }

    private func addStrokeControls(to contentView: NSView, y: CGFloat, label: String = "粗细") {
        let strokeLabel = addOptionLabel(label, x: 16, y: y + 5, width: 36, to: contentView)
        let isText = label == "字号"
        let value = isText ? (canvasView?.textPointSize ?? 20) : (canvasView?.strokeWidth ?? 4)
        let slider = NSSlider(value: Double(value), minValue: isText ? 12 : 1, maxValue: isText ? 80 : 16, target: self, action: #selector(strokeSliderChanged(_:)))
        slider.tag = isText ? 1 : 0
        slider.frame = CGRect(x: strokeLabel.frame.maxX + 8, y: y + 3, width: 190, height: 22)
        slider.numberOfTickMarks = 4
        slider.allowsTickMarkValuesOnly = false
        contentView.addSubview(slider)
        strokeSlider = slider

        let valueLabel = NSTextField(labelWithString: "\(Int(value.rounded())) \(isText ? "pt" : "px")")
        valueLabel.frame = CGRect(x: slider.frame.maxX + 6, y: y + 5, width: 44, height: 18)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.textColor = .labelColor
        contentView.addSubview(valueLabel)
        strokeValueLabel = valueLabel
    }

    private func addColorControls(to contentView: NSView, y: CGFloat) {
        let colorLabel = addOptionLabel("颜色", x: 16, y: y + 5, width: 36, to: contentView)
        addColorWells(to: contentView, origin: CGPoint(x: colorLabel.frame.maxX + 8, y: y + 2))
    }

    @discardableResult
    private func addOptionLabel(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, to contentView: NSView) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.frame = CGRect(x: x, y: y, width: width, height: 18)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        contentView.addSubview(label)
        return label
    }

    @objc private func finishEditing() {
        canvasView?.commitTextEditing()
        guard let image = canvasView?.renderedImage(scale: exportScale) else { return }
        let completion = onComplete
        closeWithoutCallback()
        completion?(image)
    }

    @objc private func cancelEditing() {
        closeWindow()
    }

    @objc private func copyImage() {
        canvasView?.commitTextEditing()
        guard let image = canvasView?.renderedImage(scale: exportScale) else { return }
        onCopy?(image)
    }

    @objc private func saveImage() {
        canvasView?.commitTextEditing()
        guard let image = canvasView?.renderedImage(scale: exportScale) else { return }
        guard onSave?(image) == true else { return }
        let completion = onComplete
        closeWithoutCallback()
        completion?(image)
    }

    @objc private func pinImage() {
        canvasView?.commitTextEditing()
        guard let image = canvasView?.renderedImage(scale: exportScale) else { return }
        onPin?(image)
    }

    func exportImage() -> NSImage? {
        canvasView?.commitTextEditing()
        return canvasView?.renderedImage(scale: exportScale)
    }

    @objc private func closeWindow() {
        guard !didClose else { return }
        didClose = true
        let close = onClose
        tearDownViews()
        close?()
    }

    private func closeWithoutCallback() {
        guard !didClose else { return }
        didClose = true
        tearDownViews()
    }

    private func tearDownViews() {
        canvasView?.dispose()
        closeOptionsWindow()
        resizeHandleView?.onResize = nil
        window?.orderOut(nil)
        window?.contentView = nil
        contentView = nil
        canvasView = nil
        scrollView = nil
        toolbarView = nil
        resizeHandleView = nil
        toolControl = nil
        shapePopup = nil
        strokeSlider = nil
        strokeValueLabel = nil
        colorWells.removeAll()
        customColorButton = nil
        zoomSlider = nil
        zoomValueLabel = nil
        onComplete = nil
        onCancel = nil
        onCopy = nil
        onSave = nil
        onPin = nil
        onClose = nil
        window = nil
    }

    private func addStandardToolbar(to contentView: NSView, toolbarSize: CGSize, origin: CGPoint) {
        let toolbar = GlassView(frame: CGRect(origin: origin, size: toolbarSize))
        toolbar.castsSoftShadow = true
        contentView.addSubview(toolbar)
        toolbarView = toolbar

        // 控件组按实际 fit 宽度居中，而不是让固定宽度外框看起来偏左。
        let fittedGroupWidth: CGFloat = 482
        let leftInset: CGFloat = max(8, (toolbarSize.width - fittedGroupWidth) / 2)
        let topRowY = toolbarSize.height - 46
        let toolControl = NSSegmentedControl(images: [
            systemImage("pencil.tip"),
            systemImage("eraser"),
            systemImage("checkerboard.rectangle"),
            systemImage("textformat")
        ], trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        toolControl.frame = CGRect(x: leftInset, y: topRowY, width: 174, height: 30)
        toolControl.segmentStyle = .separated
        toolControl.selectedSegment = -1
        toolControl.setToolTip("画笔", forSegment: 0)
        toolControl.setToolTip("橡皮", forSegment: 1)
        toolControl.setToolTip("马赛克", forSegment: 2)
        toolControl.setToolTip("文字", forSegment: 3)
        toolbar.addSubview(toolControl)
        self.toolControl = toolControl

        let shapePopup = NSPopUpButton(frame: CGRect(x: toolControl.frame.maxX + 8, y: topRowY, width: 96, height: 30), pullsDown: false)
        shapePopup.addItem(withTitle: "矩形")
        shapePopup.addItem(withTitle: "圆形")
        shapePopup.addItem(withTitle: "直线")
        shapePopup.addItem(withTitle: "箭头")
        shapePopup.item(at: 0)?.image = systemImage("rectangle")
        shapePopup.item(at: 1)?.image = systemImage("circle")
        shapePopup.item(at: 2)?.image = systemImage("line.diagonal")
        shapePopup.item(at: 3)?.image = systemImage("arrow.up.right")
        shapePopup.target = self
        shapePopup.action = #selector(shapePopupChanged(_:))
        shapePopup.toolTip = "形状：矩形"
        shapePopup.wantsLayer = true
        shapePopup.layer?.cornerRadius = 6
        shapePopup.layer?.masksToBounds = true
        toolbar.addSubview(shapePopup)
        self.shapePopup = shapePopup

        let clearButton = addIconButton(symbolName: "trash", tooltip: "清空", x: shapePopup.frame.maxX + 8, y: topRowY, action: #selector(clearAnnotations), to: toolbar)

        let actionStartX = clearButton.frame.maxX + 14
        addDivider(to: toolbar, x: actionStartX - 8, y: topRowY + 3, height: 24)
        addIconButton(symbolName: "doc.on.doc", tooltip: "复制", x: actionStartX, y: topRowY, action: #selector(copyImage), to: toolbar)
        addIconButton(symbolName: "square.and.arrow.down", tooltip: "保存", x: actionStartX + 38, y: topRowY, action: #selector(saveImage), to: toolbar)
        addIconButton(symbolName: "pin", tooltip: "贴图", x: actionStartX + 76, y: topRowY, action: #selector(pinImage), to: toolbar)
        addIconButton(symbolName: "xmark", tooltip: "关闭", x: actionStartX + 114, y: topRowY, action: #selector(closeWindow), to: toolbar, isDestructive: true)

        guard showsZoomControls else { return }
        let zoomRowY = topRowY - 40
        let zoomLabel = NSTextField(labelWithString: "缩放")
        zoomLabel.frame = CGRect(x: leftInset, y: zoomRowY + 6, width: 32, height: 18)
        zoomLabel.font = .systemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = .secondaryLabelColor
        toolbar.addSubview(zoomLabel)

        let zoomSlider = NSSlider(value: 1, minValue: 0.25, maxValue: 4.0, target: self, action: #selector(zoomSliderChanged(_:)))
        zoomSlider.frame = CGRect(x: zoomLabel.frame.maxX + 8, y: zoomRowY + 4, width: 190, height: 22)
        zoomSlider.numberOfTickMarks = 0
        zoomSlider.allowsTickMarkValuesOnly = false
        toolbar.addSubview(zoomSlider)
        self.zoomSlider = zoomSlider

        let zoomValueLabel = NSTextField(labelWithString: "1.0x")
        zoomValueLabel.frame = CGRect(x: zoomSlider.frame.maxX + 6, y: zoomRowY + 6, width: 44, height: 18)
        zoomValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomValueLabel.textColor = .labelColor
        toolbar.addSubview(zoomValueLabel)
        self.zoomValueLabel = zoomValueLabel
    }

    private func applyZoomScale() {
        guard allowsZoom, let canvasView, let scrollView, let contentView, let toolbarView, let window else { return }
        let horizontalPadding = self.horizontalPadding
        let verticalPadding = self.verticalPadding
        let topSafePadding: CGFloat = 36
        let toolbarHeight: CGFloat = showsZoomControls ? 102 : 62
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let scaledSize = CGSize(width: baseCanvasSize.width * zoomScale, height: baseCanvasSize.height * zoomScale)
        canvasView.setCanvasDisplaySize(scaledSize)
        let toolbarSize = CGSize(width: minimumToolbarWidth, height: toolbarHeight)
        let viewportSize = viewportSize(for: scaledSize, toolbarHeight: toolbarHeight, screenFrame: screenFrame)
        let contentSize = CGSize(
            width: max(viewportSize.width, toolbarSize.width) + horizontalPadding * 2,
            height: viewportSize.height + toolbarSize.height + verticalPadding * 3 + topSafePadding
        )
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.frame = CGRect(
            x: (contentSize.width - viewportSize.width) / 2,
            y: verticalPadding * 2 + toolbarHeight,
            width: viewportSize.width,
            height: viewportSize.height
        )
        resizeHandleView?.frame = resizeHandleFrame(for: scrollView.frame)
        toolbarView.frame = CGRect(
            x: (contentSize.width - toolbarSize.width) / 2,
            y: verticalPadding,
            width: toolbarSize.width,
            height: toolbarSize.height
        )
        let currentCenter = window.frame.center
        let newFrame = CGRect(
            x: currentCenter.x - contentSize.width / 2,
            y: currentCenter.y - contentSize.height / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        window.setFrame(newFrame, display: true, animate: false)
    }

    private func resizeLongScreenshot(by delta: CGSize) {
        guard allowsZoom else { return }
        let dominantDelta = abs(delta.width) > abs(delta.height) ? delta.width : -delta.height
        let nextScale = min(max(zoomScale + dominantDelta / 520, 0.45), 2.4)
        guard abs(nextScale - zoomScale) > 0.001 else { return }
        zoomScale = nextScale
        applyZoomScale()
    }

    private func resizeHandleFrame(for rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - 18, y: rect.minY + 4, width: 16, height: 16)
    }

    private func addColorWells(to toolbar: NSView, origin: CGPoint) {
        colorWells = colors.enumerated().map { index, color in
            let button = GlassButton(frame: CGRect(x: origin.x + CGFloat(index) * 32, y: origin.y, width: 24, height: 24))
            button.setAccessibilityLabel("标注颜色 \(index + 1)")
            button.title = ""
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.target = self
            button.action = #selector(colorSelected(_:))
            button.tag = index
            let selected = canvasView?.strokeColor.isEqual(color) == true
            button.state = selected ? .on : .off
            button.wantsLayer = true
            button.layer?.cornerRadius = 12
            button.layer?.masksToBounds = true
            button.layer?.backgroundColor = color.cgColor
            button.layer?.borderWidth = selected ? 3 : 1
            button.layer?.borderColor = NSColor.white.withAlphaComponent(selected ? 0.95 : 0.35).cgColor
            toolbar.addSubview(button)
            return button
        }

        let customButton = GlassButton(frame: CGRect(x: origin.x + CGFloat(colors.count) * 32 + 8, y: origin.y, width: 28, height: 24))
        customButton.setAccessibilityLabel("打开调色盘")
        customButton.title = ""
        customButton.image = systemImage("paintpalette")
        customButton.imagePosition = .imageOnly
        customButton.toolTip = "打开调色盘"
        customButton.bezelStyle = .regularSquare
        customButton.isBordered = false
        customButton.target = self
        customButton.action = #selector(showColorPanel)
        customButton.wantsLayer = true
        customButton.layer?.cornerRadius = 12
        customButton.layer?.masksToBounds = true
        customButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
        customButton.layer?.borderWidth = 1
        customButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        toolbar.addSubview(customButton)
        customColorButton = customButton
    }

    @discardableResult
    private func addIconButton(symbolName: String, tooltip: String, x: CGFloat, y: CGFloat, action: Selector, to contentView: NSView, isDestructive: Bool = false) -> NSButton {
        let button = GlassButton(image: systemImage(symbolName), target: self, action: action)
        button.setAccessibilityLabel(tooltip)
        button.frame = CGRect(x: x, y: y, width: 34, height: 30)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        if ["trash", "doc.on.doc", "square.and.arrow.down", "pin"].contains(symbolName) {
            button.useMomentaryActionSurface()
        }
        if isDestructive {
            button.contentTintColor = .systemRed
        }
        contentView.addSubview(button)
        return button
    }

    private func addDivider(to contentView: NSView, x: CGFloat, y: CGFloat, height: CGFloat) {
        let divider = NSBox(frame: CGRect(x: x, y: y, width: 1, height: height))
        divider.boxType = .separator
        contentView.addSubview(divider)
    }

    private func systemImage(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(size: CGSize(width: 16, height: 16))
    }

    private func canvasSize(for imageSize: CGSize, screenFrame: CGRect, toolbarHeight: CGFloat, horizontalPadding: CGFloat, verticalPadding: CGFloat) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGSize(width: 640, height: 420) }
        let maxWidth = max(900, screenFrame.width * 0.92 - horizontalPadding * 2)
        let maxHeight = max(640, screenFrame.height * 0.88 - toolbarHeight - verticalPadding * 3)
        let scale = min(maxWidth / imageSize.width, maxHeight / imageSize.height, 1)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func viewportSize(for canvasSize: CGSize, toolbarHeight: CGFloat, screenFrame: CGRect) -> CGSize {
        let maxWidth = max(480, screenFrame.width * 0.92 - horizontalPadding * 2)
        let maxHeight = max(360, screenFrame.height * 0.88 - toolbarHeight - verticalPadding * 3 - topSafePadding)
        return CGSize(width: min(canvasSize.width, maxWidth), height: min(canvasSize.height, maxHeight))
    }

    private func longScreenshotCanvasSize(for imageSize: CGSize, screenFrame: CGRect, horizontalPadding: CGFloat) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGSize(width: 900, height: 1600) }
        let maxWidth = min(max(820, screenFrame.width * 0.72 - horizontalPadding * 2), 980)
        let targetWidth = min(max(imageSize.width, 820), maxWidth)
        let scale = targetWidth / imageSize.width
        return CGSize(width: targetWidth, height: imageSize.height * scale)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private final class ResizeHandleView: NSView {
    var onResize: ((CGSize) -> Void)?
    private var lastPoint: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.7).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        if let lastPoint {
            onResize?(CGSize(width: point.x - lastPoint.x, height: point.y - lastPoint.y))
        }
        lastPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        lastPoint = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.secondaryLabelColor.withAlphaComponent(0.9).setStroke()
        for offset in [4.0, 8.0, 12.0] {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: bounds.maxX - CGFloat(offset), y: bounds.minY + 3))
            path.line(to: CGPoint(x: bounds.maxX - 3, y: bounds.minY + CGFloat(offset)))
            path.lineWidth = 1.2
            path.stroke()
        }
    }
}

private final class CanvasTextView: NSTextView {
    var onEscape: (() -> Void)?
    private var movingText = false
    private weak var dragCanvas: NSView?
    override func mouseDown(with event: NSEvent) {
        movingText = event.modifierFlags.contains(.option)
        if movingText { dragCanvas = superview; dragCanvas?.mouseDown(with: event) } else { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if movingText { dragCanvas?.mouseDragged(with: event) } else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if movingText { dragCanvas?.mouseUp(with: event); movingText = false; dragCanvas = nil } else { super.mouseUp(with: event) }
    }
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) } else { onEscape?() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !hasMarkedText() { onEscape?(); return }
        super.keyDown(with: event)
    }
}

private final class TextResizeHandle: NSView {
    var onDelta: ((CGFloat) -> Void)?
    private var last: CGPoint?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.controlAccentColor.cgColor; layer?.cornerRadius = 3 }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) { last = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) { let p = event.locationInWindow; if let last { onDelta?(p.x - last.x) }; last = p }
    override func mouseUp(with event: NSEvent) { last = nil }
}

final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    var tool: AnnotationTool = .none {
        willSet { if tool == .text && newValue != .text { commitTextEditing(); shapes += editableTexts; editableTexts.removeAll() } }
    }
    var strokeColor: NSColor = .systemRed { didSet { updateSelectedTextStyle() } }
    var strokeWidth: CGFloat = 4
    var textPointSize: CGFloat = 20 { didSet { updateSelectedTextStyle() } }
    var textFontName = NSFont.systemFont(ofSize: 16).familyName ?? "Helvetica Neue" { didSet { updateSelectedTextStyle() } }
    var textWeight: TextWeight = .semibold { didSet { updateSelectedTextStyle() } }
    var textUnderline = false { didSet { updateSelectedTextStyle() } }
    private(set) var editableTexts: [AnnotationShape] = []
    private(set) var selectedTextIndex: Int?
    private var textEditor: CanvasTextView?
    private var textResizeHandle: TextResizeHandle?
    private var loadingTextStyle = false
    private var textDragPoint: CGPoint?
    var onTextSelectionChanged: (() -> Void)?

    private let image: NSImage
    private let imageSize: CGSize
    private(set) var shapes: [AnnotationShape] = []
    private var currentPenPoints: [CGPoint] = []
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init(frame: CGRect, image: NSImage) {
        self.image = image
        imageSize = image.size
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // 画布不是装饰面板：完整展示矩形源图，去掉外溢边框和重复阴影。
        layer?.cornerRadius = 0
        layer?.masksToBounds = true
        layer?.borderWidth = 0
        layer?.borderColor = nil
        layer?.shadowOpacity = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func clear() {
        removeTextEditor()
        editableTexts.removeAll()
        shapes.removeAll()
        currentPenPoints.removeAll()
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
    }

    func dispose() {
        onTextSelectionChanged = nil
        clear()
        layer?.contents = nil
        removeFromSuperview()
    }

    private func resizeSelectedText(by delta: CGFloat) {
        guard let index = selectedTextIndex, let editor = textEditor,
              case let .text(text, origin, color, size, name, weight, underline) = editableTexts[index] else { return }
        let next = min(max(size + delta * 0.35, 12), 80)
        guard abs(next - size) > 0.01 else { return }
        editableTexts[index] = .text(text, origin, color, next, name, weight, underline)
        textPointSize = next
        updateSelectedTextStyle()
        _ = editor
    }

    func setCanvasDisplaySize(_ size: CGSize) {
        guard size.width > 1, size.height > 1, bounds.size != size else { return }
        let selection = selectedTextIndex
        commitTextEditing()
        let oldSize = CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
        let scaleX = size.width / oldSize.width
        let scaleY = size.height / oldSize.height
        shapes = shapes.map { scaledShape($0, scaleX: scaleX, scaleY: scaleY) }
        editableTexts = editableTexts.map { scaledShape($0, scaleX: scaleX, scaleY: scaleY) }
        currentPenPoints = currentPenPoints.map { scaledPoint($0, scaleX: scaleX, scaleY: scaleY) }
        dragStart = dragStart.map { scaledPoint($0, scaleX: scaleX, scaleY: scaleY) }
        dragCurrent = dragCurrent.map { scaledPoint($0, scaleX: scaleX, scaleY: scaleY) }
        frame = CGRect(origin: .zero, size: size)
        if let selection, editableTexts.indices.contains(selection) { selectText(at: selection) }
        needsDisplay = true
    }

    private func scaledShape(_ shape: AnnotationShape, scaleX: CGFloat, scaleY: CGFloat) -> AnnotationShape {
        let lineScale = (scaleX + scaleY) / 2
        switch shape {
        case let .pen(points, color, lineWidth):
            return .pen(points.map { scaledPoint($0, scaleX: scaleX, scaleY: scaleY) }, color, lineWidth * lineScale)
        case let .text(text, origin, color, fontSize, fontName, weight, underline):
            return .text(text, scaledPoint(origin, scaleX: scaleX, scaleY: scaleY), color, fontSize * lineScale, fontName, weight, underline)
        case let .rectangle(rect, color, lineWidth):
            return .rectangle(scaledRect(rect, scaleX: scaleX, scaleY: scaleY), color, lineWidth * lineScale)
        case let .oval(rect, color, lineWidth):
            return .oval(scaledRect(rect, scaleX: scaleX, scaleY: scaleY), color, lineWidth * lineScale)
        case let .line(start, end, color, lineWidth):
            return .line(scaledPoint(start, scaleX: scaleX, scaleY: scaleY), scaledPoint(end, scaleX: scaleX, scaleY: scaleY), color, lineWidth * lineScale)
        case let .arrow(start, end, color, lineWidth):
            return .arrow(scaledPoint(start, scaleX: scaleX, scaleY: scaleY), scaledPoint(end, scaleX: scaleX, scaleY: scaleY), color, lineWidth * lineScale)
        case let .mosaic(rect):
            return .mosaic(scaledRect(rect, scaleX: scaleX, scaleY: scaleY))
        }
    }

    private func scaledPoint(_ point: CGPoint, scaleX: CGFloat, scaleY: CGFloat) -> CGPoint {
        CGPoint(x: point.x * scaleX, y: point.y * scaleY)
    }

    private func scaledRect(_ rect: CGRect, scaleX: CGFloat, scaleY: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
    }

    func renderedImage(scale: CGFloat = 1) -> NSImage {
        commitTextEditing()
        let outputScale = CGFloat(ScreenshotExportScale.normalized(Double(scale)))
        let source = ImageEncoding.sourceCGImage(from: image)
        // 无批注的原始导出直接保留源位图，避免 Retina 降采样及多余重绘。
        if outputScale == 1, shapes.isEmpty, editableTexts.isEmpty, let source {
            return NSImage(cgImage: source, size: imageSize)
        }
        let nativeSize = source.map { CGSize(width: $0.width, height: $0.height) } ?? imageSize
        let outputSize = CGSize(width: nativeSize.width * outputScale, height: nativeSize.height * outputScale)
        let pixelWidth = max(1, Int(outputSize.width.rounded()))
        let pixelHeight = max(1, Int(outputSize.height.rounded()))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: outputSize)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = outputScale == 1 ? .none : .high
        let scaleX = outputSize.width / max(bounds.width, 1)
        let scaleY = outputSize.height / max(bounds.height, 1)
        context.scaleBy(x: scaleX, y: scaleY)
        // 显式使用源位图，避免 AppKit 因预览点尺寸选择低分辨率 representation。
        if let source {
            context.interpolationQuality = outputScale == 1 ? .none : .high
            context.draw(source, in: bounds)
            shapes.forEach(drawShape)
            editableTexts.forEach(drawShape)
        } else {
            drawCanvas(in: bounds, includeDraft: false)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { return NSImage(size: outputSize) }
        return NSImage(cgImage: cgImage, size: outputSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCanvas(in: bounds, includeDraft: true)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if tool == .none {
            window?.performDrag(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragCurrent = point
        if tool == .pen {
            currentPenPoints = [point]
        } else if tool == .text {
            let borderSelection = textEditor.flatMap { editor -> Int? in
                editor.frame.insetBy(dx: -6, dy: -6).contains(point) && !editor.frame.insetBy(dx: 2, dy: 2).contains(point) ? selectedTextIndex : nil
            }
            commitTextEditing()
            if let index = borderSelection.flatMap({ editableTexts.indices.contains($0) ? $0 : nil }) ?? editableTexts.indices.reversed().first(where: { shapeBounds(editableTexts[$0]).insetBy(dx: -6, dy: -6).contains(point) }) {
                selectText(at: index)
                textDragPoint = point
            } else { beginText(at: point) }
            dragStart = nil
            dragCurrent = nil
        } else if tool == .eraser {
            eraseAnnotations(around: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard tool != .none else { return }

        let point = convert(event.locationInWindow, from: nil)
        if tool == .text {
            if let last = textDragPoint { moveSelectedText(by: CGSize(width: point.x - last.x, height: point.y - last.y)); textDragPoint = point }
            return
        }
        dragCurrent = point
        if tool == .pen {
            currentPenPoints.append(point)
        } else if tool == .eraser {
            eraseAnnotations(around: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        textDragPoint = nil
        guard tool != .none else { return }

        dragCurrent = convert(event.locationInWindow, from: nil)
        switch tool {
        case .none:
            break
        case .pen:
            if currentPenPoints.count > 1 { shapes.append(.pen(currentPenPoints, strokeColor, strokeWidth)) }
            currentPenPoints.removeAll()
        case .text:
            break
        case .eraser:
            if let dragCurrent { eraseAnnotations(around: dragCurrent) }
        case .rectangle:
            if let rect = currentRect, rect.width > 2, rect.height > 2 { shapes.append(.rectangle(rect, strokeColor, strokeWidth)) }
        case .oval:
            if let rect = currentRect, rect.width > 2, rect.height > 2 { shapes.append(.oval(rect, strokeColor, strokeWidth)) }
        case .line:
            if let dragStart, let dragCurrent { shapes.append(.line(dragStart, dragCurrent, strokeColor, strokeWidth)) }
        case .arrow:
            if let dragStart, let dragCurrent { shapes.append(.arrow(dragStart, dragCurrent, strokeColor, strokeWidth)) }
        case .mosaic:
            if let rect = currentRect, rect.width > 2, rect.height > 2 { shapes.append(.mosaic(rect)) }
        }
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
    }

    private var currentRect: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return CGRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragStart.x - dragCurrent.x),
            height: abs(dragStart.y - dragCurrent.y)
        )
    }

    private func drawCanvas(in rect: CGRect, includeDraft: Bool) {
        NSColor.clear.setFill()
        rect.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        shapes.forEach(drawShape)
        for (index, shape) in editableTexts.enumerated() where !includeDraft || index != selectedTextIndex {
            drawShape(shape)
        }
        if includeDraft, let editor = textEditor {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: editor.frame.insetBy(dx: -4, dy: -4))
            border.lineWidth = 1
            border.stroke()
        }
        if includeDraft {
            drawDraft()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDraft() {
        switch tool {
        case .none:
            break
        case .pen:
            drawPen(currentPenPoints, color: strokeColor, lineWidth: strokeWidth)
        case .text:
            break
        case .eraser:
            if let dragCurrent { drawEraser(at: dragCurrent) }
        case .rectangle:
            if let rect = currentRect { drawRectangle(rect, color: strokeColor, lineWidth: strokeWidth) }
        case .oval:
            if let rect = currentRect { drawOval(rect, color: strokeColor, lineWidth: strokeWidth) }
        case .line:
            if let dragStart, let dragCurrent { drawLine(from: dragStart, to: dragCurrent, color: strokeColor, lineWidth: strokeWidth) }
        case .arrow:
            if let dragStart, let dragCurrent { drawArrow(from: dragStart, to: dragCurrent, color: strokeColor, lineWidth: strokeWidth) }
        case .mosaic:
            if let rect = currentRect { drawMosaic(rect) }
        }
    }

    private func drawShape(_ shape: AnnotationShape) {
        switch shape {
        case let .pen(points, color, lineWidth):
            drawPen(points, color: color, lineWidth: lineWidth)
        case let .text(text, origin, color, fontSize, fontName, weight, underline):
            drawText(text, at: origin, color: color, fontSize: fontSize, fontName: fontName, weight: weight, underline: underline)
        case let .rectangle(rect, color, lineWidth):
            drawRectangle(rect, color: color, lineWidth: lineWidth)
        case let .oval(rect, color, lineWidth):
            drawOval(rect, color: color, lineWidth: lineWidth)
        case let .line(start, end, color, lineWidth):
            drawLine(from: start, to: end, color: color, lineWidth: lineWidth)
        case let .arrow(start, end, color, lineWidth):
            drawArrow(from: start, to: end, color: color, lineWidth: lineWidth)
        case let .mosaic(rect):
            drawMosaic(rect)
        }
    }

    private func drawPen(_ points: [CGPoint], color: NSColor, lineWidth: CGFloat) {
        guard points.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        color.setStroke()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawText(_ text: String, at origin: CGPoint, color: NSColor, fontSize: CGFloat, fontName: String, weight: TextWeight, underline: Bool) {
        let attributes = textAttributes(color: color, size: fontSize, name: fontName, weight: weight, underline: underline)
        let maxWidth = max(1, bounds.maxX - origin.x - 4)
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral.size
        let drawRect = CGRect(x: origin.x, y: origin.y - size.height, width: maxWidth, height: size.height)
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private func drawRectangle(_ rect: CGRect, color: NSColor, lineWidth: CGFloat) {
        color.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = lineWidth
        path.stroke()
    }

    private func drawOval(_ rect: CGRect, color: NSColor, lineWidth: CGFloat) {
        color.setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = lineWidth
        path.stroke()
    }

    private func drawLine(from start: CGPoint, to end: CGPoint, color: NSColor, lineWidth: CGFloat) {
        color.setStroke()
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, color: NSColor, lineWidth: CGFloat) {
        drawLine(from: start, to: end, color: color, lineWidth: lineWidth)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(lineWidth * 4, 14)
        let headAngle = CGFloat.pi / 7
        let left = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )

        color.setStroke()
        let head = NSBezierPath()
        head.move(to: left)
        head.line(to: end)
        head.line(to: right)
        head.lineWidth = lineWidth
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.stroke()
    }

    private func drawMosaic(_ rect: CGRect) {
        let clipped = rect.intersection(bounds)
        guard clipped.width > 1, clipped.height > 1 else { return }

        let blockSize: CGFloat = 14
        let smallSize = CGSize(width: max(1, ceil(clipped.width / blockSize)), height: max(1, ceil(clipped.height / blockSize)))
        let sourceRect = imageSourceRect(for: clipped)
        let smallImage = NSImage(size: smallSize)
        smallImage.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: smallSize), from: sourceRect, operation: .sourceOver, fraction: 1)
        smallImage.unlockFocus()

        let context = NSGraphicsContext.current
        let previousInterpolation = context?.imageInterpolation ?? .default
        context?.imageInterpolation = .none
        smallImage.draw(in: clipped, from: CGRect(origin: .zero, size: smallSize), operation: .sourceOver, fraction: 1)
        context?.imageInterpolation = previousInterpolation
    }

    private func imageSourceRect(for rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX / max(bounds.width, 1) * imageSize.width,
            y: rect.minY / max(bounds.height, 1) * imageSize.height,
            width: rect.width / max(bounds.width, 1) * imageSize.width,
            height: rect.height / max(bounds.height, 1) * imageSize.height
        )
    }

    private func eraseAnnotations(around point: CGPoint) {
        let radius = max(strokeWidth * 2.5, 12)
        let eraseRect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        shapes.removeAll { shapeBounds($0).insetBy(dx: -radius, dy: -radius).intersects(eraseRect) }
    }

    private func drawEraser(at point: CGPoint) {
        let radius = max(strokeWidth * 2.5, 12)
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        NSColor.white.withAlphaComponent(0.45).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 1.5
        path.stroke()
    }

    private func shapeBounds(_ shape: AnnotationShape) -> CGRect {
        switch shape {
        case let .pen(points, _, lineWidth):
            return pointsBounds(points).insetBy(dx: -lineWidth, dy: -lineWidth)
        case let .text(text, origin, _, fontSize, fontName, weight, _):
            return textBounds(text, at: origin, fontSize: fontSize, fontName: fontName, weight: weight)
        case let .rectangle(rect, _, lineWidth), let .oval(rect, _, lineWidth):
            return rect.insetBy(dx: -lineWidth, dy: -lineWidth)
        case let .line(start, end, _, lineWidth), let .arrow(start, end, _, lineWidth):
            return pointsBounds([start, end]).insetBy(dx: -lineWidth * 4, dy: -lineWidth * 4)
        case let .mosaic(rect):
            return rect
        }
    }

    private func pointsBounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }

    private var textFontSize: CGFloat {
        textPointSize
    }

    private func clampedTextOrigin(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX + 4), max(bounds.minX + 4, bounds.maxX - textFontSize - 8)),
            y: min(max(point.y, bounds.minY + textFontSize + 4), bounds.maxY - 4)
        )
    }

    private func textBounds(_ text: String, at origin: CGPoint, fontSize: CGFloat, fontName: String, weight: TextWeight) -> CGRect {
        let attributes = textAttributes(color: .black, size: fontSize, name: fontName, weight: weight, underline: false)
        let maxWidth = max(1, bounds.maxX - origin.x - 4)
        let size = NSAttributedString(string: text, attributes: attributes).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral.size
        return CGRect(x: origin.x, y: origin.y - size.height, width: min(maxWidth, size.width), height: size.height)
    }

    // 仅当前文字工具会话中的对象可以进入编辑器；固定对象从不参与命中检测。
    func beginText(at point: CGPoint) {
        guard tool == .text else { return }
        commitTextEditing()
        editableTexts.append(.text("", clampedTextOrigin(point), strokeColor, textFontSize, textFontName, textWeight, textUnderline))
        selectText(at: editableTexts.count - 1)
    }

    func selectText(at index: Int) {
        guard tool == .text, editableTexts.indices.contains(index) else { return }
        guard case let .text(text, _, color, size, name, weight, underline) = editableTexts[index] else { return }
        removeTextEditor()
        selectedTextIndex = index
        loadingTextStyle = true
        strokeColor = color
        textPointSize = size
        textFontName = name
        textWeight = weight
        textUnderline = underline
        loadingTextStyle = false
        let editor = CanvasTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        // 容器保留边界换行宽度，视图只包围实际文字；禁止 AppKit 用视图宽度反写容器。
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.autoresizingMask = []
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.toolTip = "直接输入文字；拖动边框移动，或按住 Option 拖动文字。Esc 结束当前输入。"
        editor.string = text
        editor.delegate = self
        editor.onEscape = { [weak self] in self?.commitTextEditing() }
        textEditor = editor
        addSubview(editor)
        let handle = TextResizeHandle(frame: .zero)
        handle.onDelta = { [weak self] delta in self?.resizeSelectedText(by: delta) }
        addSubview(handle)
        textResizeHandle = handle
        updateSelectedTextStyle()
        onTextSelectionChanged?()
        window?.makeKey()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    private func removeTextEditor() {
        if window?.firstResponder === textEditor { window?.makeFirstResponder(self) }
        textEditor?.delegate = nil
        textEditor?.onEscape = nil
        textEditor?.removeFromSuperview()
        textResizeHandle?.removeFromSuperview()
        textResizeHandle = nil
        textEditor = nil
        selectedTextIndex = nil
        textDragPoint = nil
        needsDisplay = true
    }

    @discardableResult
    func commitTextEditing() -> Bool {
        guard let index = selectedTextIndex, let editor = textEditor else { return false }
        // 将输入法的当前组合文本保存在对象中，再结束输入上下文。
        editor.unmarkText()
        updateSelectedTextStyle()
        let isEmpty = editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        removeTextEditor()
        if isEmpty { editableTexts.remove(at: index) }
        return true
    }

    func textDidChange(_ notification: Notification) { updateSelectedTextStyle() }

    private func updateSelectedTextStyle() {
        guard !loadingTextStyle, let index = selectedTextIndex, let editor = textEditor,
              editableTexts.indices.contains(index),
              case let .text(_, origin, _, _, _, _, _) = editableTexts[index] else { return }
        editableTexts[index] = .text(editor.string, origin, strokeColor, textPointSize, textFontName, textWeight, textUnderline)
        let attributes = textAttributes(color: strokeColor, size: textPointSize, name: textFontName, weight: textWeight, underline: textUnderline)
        editor.typingAttributes = attributes
        // 组合输入期间不重写输入法的临时属性或选区。
        if !editor.hasMarkedText() {
            editor.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        editor.insertionPointColor = strokeColor
        layoutTextEditor()
    }

    private func layoutTextEditor() {
        guard let index = selectedTextIndex, let editor = textEditor,
              case let .text(text, origin, color, size, name, weight, underline) = editableTexts[index],
              let container = editor.textContainer, let manager = editor.layoutManager else { return }
        let maxWidth = max(1, bounds.maxX - origin.x - 4)
        container.containerSize = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        // 最后一处换行后的空行也需要容纳插入光标。
        let extraHeight = manager.extraLineFragmentTextContainer === container ? manager.extraLineFragmentRect.maxY : 0
        let width = min(maxWidth, max(text.isEmpty ? 12 : 1, ceil(used.maxX) + 2))
        let height = min(max(1, bounds.height - 8), max(ceil(size * 1.3), ceil(max(used.maxY, extraHeight))))
        let top = min(bounds.maxY - 4, max(origin.y, bounds.minY + height + 4))
        editableTexts[index] = .text(text, CGPoint(x: origin.x, y: top), color, size, name, weight, underline)
        // NSTextView 为翻转坐标系，画布不是：保持文字左上角不随输入行数变化。
        editor.frame = CGRect(x: origin.x, y: top - height, width: width, height: height)
        textResizeHandle?.frame = CGRect(x: editor.frame.maxX - 8, y: editor.frame.minY - 8, width: 14, height: 14)
        needsDisplay = true
    }

    func moveSelectedText(by delta: CGSize) {
        guard let index = selectedTextIndex,
              case let .text(text, origin, color, size, name, weight, underline) = editableTexts[index] else { return }
        let next = clampedTextOrigin(CGPoint(x: origin.x + delta.width, y: origin.y + delta.height))
        editableTexts[index] = .text(text, next, color, size, name, weight, underline)
        layoutTextEditor()
    }

    private func textAttributes(color: NSColor, size: CGFloat, name: String, weight: TextWeight, underline: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: textFont(name: name, size: size, weight: weight), .foregroundColor: color,
                .paragraphStyle: paragraph, .strokeColor: NSColor.black.withAlphaComponent(0.18),
                .strokeWidth: -1.5, .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0]
    }

    private func textFont(name: String, size: CGFloat, weight: TextWeight) -> NSFont {
        if let font = NSFont(name: name, size: size),
           let weighted = NSFont(descriptor: font.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight.fontWeight.rawValue]
           ]), size: size) { return weighted }
        return .systemFont(ofSize: size, weight: weight.fontWeight)
    }
}
