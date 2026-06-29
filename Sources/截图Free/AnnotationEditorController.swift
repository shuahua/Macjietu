import AppKit

enum AnnotationTool: String {
    case none = ""
    case pen = "画笔"
    case eraser = "橡皮"
    case rectangle = "矩形"
    case oval = "圆形"
    case line = "直线"
    case arrow = "箭头"
    case mosaic = "马赛克"
}

enum AnnotationShape {
    case pen([CGPoint], NSColor, CGFloat)
    case rectangle(CGRect, NSColor, CGFloat)
    case oval(CGRect, NSColor, CGFloat)
    case line(CGPoint, CGPoint, NSColor, CGFloat)
    case arrow(CGPoint, CGPoint, NSColor, CGFloat)
    case mosaic(CGRect)
}

private final class AnnotationEditorWindow: NSWindow {
    var onEscape: (() -> Void)?

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

@MainActor
final class AnnotationEditorController: NSObject {
    private let minimumToolbarWidth: CGFloat = 480
    private let horizontalPadding: CGFloat = 20
    private let verticalPadding: CGFloat = 16
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
    private var toolbarView: NSVisualEffectView?
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
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 16
        let topSafePadding: CGFloat = 36
        let toolbarHeight: CGFloat = 138
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
        let scrollView = NSScrollView(frame: canvasFrame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = canvas
        scrollView.autohidesScrollers = false
        scrollView.allowsMagnification = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 12
        contentView.addSubview(scrollView)
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showStandardEditor() {
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 16
        let topSafePadding: CGFloat = 36
        let toolbarHeight: CGFloat = 138
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
        let canvas = AnnotationCanvasView(frame: canvasFrame, image: image)
        contentView.addSubview(canvas)
        self.contentView = contentView
        canvasView = canvas
        scrollView = nil

        let toolbarOrigin = CGPoint(x: (contentSize.width - toolbarSize.width) / 2, y: verticalPadding)
        addStandardToolbar(to: contentView, toolbarSize: toolbarSize, origin: toolbarOrigin)

        let rect = CGRect(x: screenFrame.midX - contentSize.width / 2, y: screenFrame.midY - contentSize.height / 2, width: contentSize.width, height: contentSize.height)
        let window = makeEditorWindow(rect: rect, contentView: contentView)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeEditorWindow(rect: CGRect, contentView: NSView) -> AnnotationEditorWindow {
        let window = AnnotationEditorWindow(contentRect: rect, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.onEscape = { [weak self] in self?.closeWindow() }
        window.title = "截图编辑"
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = contentView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.hasShadow = true
        return window
    }

    @objc private func selectPen() {
        deactivateShapeTool()
        canvasView?.tool = .pen
    }

    @objc private func selectEraser() {
        deactivateShapeTool()
        canvasView?.tool = .eraser
    }

    @objc private func selectRectangle() {
        selectedShapeTool = .rectangle
        isShapeToolActive = true
        toolControl?.selectedSegment = -1
        canvasView?.tool = .rectangle
        updateShapePopup(selectedIndex: 0)
    }

    @objc private func selectOval() {
        selectedShapeTool = .oval
        isShapeToolActive = true
        toolControl?.selectedSegment = -1
        canvasView?.tool = .oval
        updateShapePopup(selectedIndex: 1)
    }

    @objc private func selectLine() {
        selectedShapeTool = .line
        isShapeToolActive = true
        toolControl?.selectedSegment = -1
        canvasView?.tool = .line
        updateShapePopup(selectedIndex: 2)
    }

    @objc private func selectArrow() {
        selectedShapeTool = .arrow
        isShapeToolActive = true
        toolControl?.selectedSegment = -1
        canvasView?.tool = .arrow
        updateShapePopup(selectedIndex: 3)
    }

    @objc private func selectMosaic() {
        deactivateShapeTool()
        canvasView?.tool = .mosaic
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        if canvasView?.tool == tool(for: sender.selectedSegment) {
            canvasView?.tool = .none
            deactivateShapeTool()
            sender.selectedSegment = -1
            return
        }

        switch sender.selectedSegment {
        case -1:
            canvasView?.tool = .none
        case 1:
            selectEraser()
        case 2:
            selectMosaic()
        default:
            selectPen()
        }
    }

    private func tool(for segment: Int) -> AnnotationTool {
        switch segment {
        case 0: return .pen
        case 1: return .eraser
        case 2: return .mosaic
        default: return .none
        }
    }

    @objc private func shapePopupChanged(_ sender: NSPopUpButton) {
        let selectedTool = shapeTool(for: sender.indexOfSelectedItem)
        if isShapeToolActive && selectedTool == selectedShapeTool {
            deactivateShapeTool()
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

    @objc private func finishEditing() {
        guard let image = canvasView?.renderedImage(scale: exportScale) else { return }
        let completion = onComplete
        closeWithoutCallback()
        completion?(image)
    }

    @objc private func cancelEditing() {
        closeWindow()
    }

    @objc private func copyImage() {
        guard let image = canvasView?.renderedImage(scale: exportScale) else { return }
        onCopy?(image)
    }

    @objc private func saveImage() {
        guard let image = canvasView?.renderedImage(scale: exportScale) else { return }
        guard onSave?(image) == true else { return }
        let completion = onComplete
        closeWithoutCallback()
        completion?(image)
    }

    @objc private func pinImage() {
        guard let image = canvasView?.renderedImage(scale: exportScale) else { return }
        onPin?(image)
    }

    func exportImage() -> NSImage? {
        canvasView?.renderedImage(scale: exportScale)
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
        let toolbar = NSVisualEffectView(frame: CGRect(origin: origin, size: toolbarSize))
        toolbar.material = .popover
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 16
        toolbar.layer?.borderWidth = 1
        toolbar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        toolbar.layer?.shadowColor = NSColor.black.cgColor
        toolbar.layer?.shadowOpacity = 0.18
        toolbar.layer?.shadowRadius = 14
        toolbar.layer?.shadowOffset = CGSize(width: 0, height: 4)
        contentView.addSubview(toolbar)
        toolbarView = toolbar

        let leftInset: CGFloat = 16
        let topRowY = toolbarSize.height - 42
        let strokeRowY = topRowY - 40
        let colorRowY = strokeRowY - 36
        let toolControl = NSSegmentedControl(images: [
            systemImage("pencil.tip"),
            systemImage("eraser"),
            systemImage("checkerboard.rectangle")
        ], trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        toolControl.frame = CGRect(x: leftInset, y: topRowY, width: 132, height: 30)
        toolControl.segmentStyle = .separated
        toolControl.selectedSegment = -1
        toolControl.setToolTip("画笔", forSegment: 0)
        toolControl.setToolTip("橡皮", forSegment: 1)
        toolControl.setToolTip("马赛克", forSegment: 2)
        toolbar.addSubview(toolControl)
        self.toolControl = toolControl

        let shapePopup = NSPopUpButton(frame: CGRect(x: toolControl.frame.maxX + 8, y: topRowY, width: 104, height: 30), pullsDown: false)
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
        toolbar.addSubview(shapePopup)
        self.shapePopup = shapePopup

        let clearButton = addIconButton(symbolName: "trash", tooltip: "清空", x: shapePopup.frame.maxX + 8, y: topRowY, action: #selector(clearAnnotations), to: toolbar)

        let actionStartX = clearButton.frame.maxX + 14
        addDivider(to: toolbar, x: actionStartX - 8, y: topRowY + 3, height: 24)
        addIconButton(symbolName: "doc.on.doc", tooltip: "复制", x: actionStartX, y: topRowY, action: #selector(copyImage), to: toolbar)
        addIconButton(symbolName: "square.and.arrow.down", tooltip: "保存", x: actionStartX + 38, y: topRowY, action: #selector(saveImage), to: toolbar)
        addIconButton(symbolName: "pin", tooltip: "贴图", x: actionStartX + 76, y: topRowY, action: #selector(pinImage), to: toolbar)
        addIconButton(symbolName: "xmark", tooltip: "关闭", x: actionStartX + 114, y: topRowY, action: #selector(closeWindow), to: toolbar, isDestructive: true)

        let strokeLabel = NSTextField(labelWithString: "粗细")
        strokeLabel.frame = CGRect(x: leftInset, y: strokeRowY + 6, width: 32, height: 18)
        strokeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        strokeLabel.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        toolbar.addSubview(strokeLabel)

        let slider = NSSlider(value: 4, minValue: 1, maxValue: 16, target: self, action: #selector(strokeSliderChanged(_:)))
        let sliderWidth: CGFloat = 190
        slider.frame = CGRect(x: strokeLabel.frame.maxX + 8, y: strokeRowY + 4, width: sliderWidth, height: 22)
        slider.numberOfTickMarks = 4
        slider.allowsTickMarkValuesOnly = false
        toolbar.addSubview(slider)
        strokeSlider = slider

        let valueLabel = NSTextField(labelWithString: "4 px")
        valueLabel.frame = CGRect(x: slider.frame.maxX + 6, y: strokeRowY + 6, width: 38, height: 18)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        toolbar.addSubview(valueLabel)
        strokeValueLabel = valueLabel

        let colorLabel = NSTextField(labelWithString: "颜色")
        colorLabel.frame = CGRect(x: leftInset, y: colorRowY + 6, width: 32, height: 18)
        colorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        colorLabel.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        toolbar.addSubview(colorLabel)
        addColorWells(to: toolbar, origin: CGPoint(x: colorLabel.frame.maxX + 8, y: colorRowY + 3))

        guard showsZoomControls else { return }
        let zoomRowY = colorRowY - 40
        let zoomLabel = NSTextField(labelWithString: "缩放")
        zoomLabel.frame = CGRect(x: leftInset, y: zoomRowY + 6, width: 32, height: 18)
        zoomLabel.font = .systemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = NSColor.labelColor.withAlphaComponent(0.82)
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
        zoomValueLabel.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        toolbar.addSubview(zoomValueLabel)
        self.zoomValueLabel = zoomValueLabel
    }

    private func applyZoomScale() {
        guard allowsZoom, let canvasView, let scrollView, let contentView, let toolbarView, let window else { return }
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 16
        let topSafePadding: CGFloat = 36
        let toolbarHeight: CGFloat = showsZoomControls ? 178 : 138
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
            let button = NSButton(frame: CGRect(x: origin.x + CGFloat(index) * 32, y: origin.y, width: 24, height: 24))
            button.title = ""
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.target = self
            button.action = #selector(colorSelected(_:))
            button.tag = index
            button.state = index == 0 ? .on : .off
            button.wantsLayer = true
            button.layer?.cornerRadius = 12
            button.layer?.backgroundColor = color.cgColor
            button.layer?.borderWidth = index == 0 ? 3 : 1
            button.layer?.borderColor = NSColor.white.withAlphaComponent(index == 0 ? 0.95 : 0.35).cgColor
            toolbar.addSubview(button)
            return button
        }

        let customButton = NSButton(frame: CGRect(x: origin.x + CGFloat(colors.count) * 32 + 8, y: origin.y, width: 28, height: 24))
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
        customButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
        customButton.layer?.borderWidth = 1
        customButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        toolbar.addSubview(customButton)
        customColorButton = customButton
    }

    @discardableResult
    private func addIconButton(symbolName: String, tooltip: String, x: CGFloat, y: CGFloat, action: Selector, to contentView: NSView, isDestructive: Bool = false) -> NSButton {
        let button = NSButton(image: systemImage(symbolName), target: self, action: action)
        button.frame = CGRect(x: x, y: y, width: 34, height: 30)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
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

final class AnnotationCanvasView: NSView {
    var tool: AnnotationTool = .none
    var strokeColor: NSColor = .systemRed
    var strokeWidth: CGFloat = 4

    private let image: NSImage
    private let imageSize: CGSize
    private var shapes: [AnnotationShape] = []
    private var currentPenPoints: [CGPoint] = []
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init(frame: CGRect, image: NSImage) {
        self.image = image
        imageSize = image.size
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = false
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: 4)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func clear() {
        shapes.removeAll()
        currentPenPoints.removeAll()
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
    }

    func dispose() {
        clear()
        layer?.contents = nil
        removeFromSuperview()
    }

    func setCanvasDisplaySize(_ size: CGSize) {
        guard size.width > 1, size.height > 1, bounds.size != size else { return }
        let oldSize = CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
        let scaleX = size.width / oldSize.width
        let scaleY = size.height / oldSize.height
        shapes = shapes.map { scaledShape($0, scaleX: scaleX, scaleY: scaleY) }
        currentPenPoints = currentPenPoints.map { scaledPoint($0, scaleX: scaleX, scaleY: scaleY) }
        dragStart = dragStart.map { scaledPoint($0, scaleX: scaleX, scaleY: scaleY) }
        dragCurrent = dragCurrent.map { scaledPoint($0, scaleX: scaleX, scaleY: scaleY) }
        frame = CGRect(origin: .zero, size: size)
        needsDisplay = true
    }

    private func scaledShape(_ shape: AnnotationShape, scaleX: CGFloat, scaleY: CGFloat) -> AnnotationShape {
        let lineScale = (scaleX + scaleY) / 2
        switch shape {
        case let .pen(points, color, lineWidth):
            return .pen(points.map { scaledPoint($0, scaleX: scaleX, scaleY: scaleY) }, color, lineWidth * lineScale)
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
        let outputScale = max(scale, 1)
        let outputSize = CGSize(width: imageSize.width * outputScale, height: imageSize.height * outputScale)
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
        let scaleX = outputSize.width / max(bounds.width, 1)
        let scaleY = outputSize.height / max(bounds.height, 1)
        context.scaleBy(x: scaleX, y: scaleY)
        drawCanvas(in: bounds, includeDraft: false)
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
        } else if tool == .eraser {
            eraseAnnotations(around: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard tool != .none else { return }

        let point = convert(event.locationInWindow, from: nil)
        dragCurrent = point
        if tool == .pen {
            currentPenPoints.append(point)
        } else if tool == .eraser {
            eraseAnnotations(around: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard tool != .none else { return }

        dragCurrent = convert(event.locationInWindow, from: nil)
        switch tool {
        case .none:
            break
        case .pen:
            if currentPenPoints.count > 1 { shapes.append(.pen(currentPenPoints, strokeColor, strokeWidth)) }
            currentPenPoints.removeAll()
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
}
