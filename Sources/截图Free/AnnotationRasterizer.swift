import AppKit

/// 不含 NSView/输入上下文的只读渲染快照；由串行工作队列独占使用。
final class AnnotationRasterizer: @unchecked Sendable {
    let source: CGImage
    let bounds: CGRect
    let shapes: [AnnotationShape]
    let scale: CGFloat
    init(source: CGImage, bounds: CGRect, shapes: [AnnotationShape], scale: CGFloat) {
        self.source = source; self.bounds = bounds; self.shapes = shapes; self.scale = scale
    }

    func pngData() throws -> Data {
        let cg = try renderedCGImage()
        guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.imageEncodingFailed
        }
        return data
    }

    func renderedCGImage() throws -> CGImage {
        let scale = CGFloat(ScreenshotExportScale.normalized(Double(scale)))
        if scale == 1 && shapes.isEmpty { return source }
        let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
        guard let context = CGContext(data: nil, width: Int(size.width.rounded()), height: Int(size.height.rounded()),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenCaptureError.imageEncodingFailed }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = scale == 1 ? .none : .high
        context.scaleBy(x: size.width / max(bounds.width, 1), y: size.height / max(bounds.height, 1))
        context.interpolationQuality = scale == 1 ? .none : .high
        context.draw(source, in: bounds)
        for shape in shapes { draw(shape) }
        guard let result = context.makeImage() else { throw ScreenCaptureError.imageEncodingFailed }
        return result
    }

    private func stroke(_ points: [CGPoint], color: NSColor, width: CGFloat) {
        guard let first = points.first, points.count > 1 else { return }
        let path = NSBezierPath(); path.move(to: first)
        points.dropFirst().forEach { path.line(to: $0) }
        color.setStroke(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.stroke()
    }

    private func draw(_ shape: AnnotationShape) {
        switch shape {
        case let .pen(points, color, width): stroke(points, color: color, width: width)
        case let .line(start, end, color, width): stroke([start, end], color: color, width: width)
        case let .arrow(start, end, color, width):
            stroke([start, end], color: color, width: width)
            let angle = atan2(end.y - start.y, end.x - start.x), length = max(width * 4, 14), head = CGFloat.pi / 7
            stroke([CGPoint(x: end.x - length * cos(angle - head), y: end.y - length * sin(angle - head)), end,
                    CGPoint(x: end.x - length * cos(angle + head), y: end.y - length * sin(angle + head))], color: color, width: width)
        case let .rectangle(rect, color, width):
            color.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = width; path.stroke()
        case let .oval(rect, color, width):
            color.setStroke(); let path = NSBezierPath(ovalIn: rect); path.lineWidth = width; path.stroke()
        case let .text(text, origin, color, size, name, weight, underline):
            let font = NSFont(name: name, size: size).flatMap {
                NSFont(descriptor: $0.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.fontWeight.rawValue]]), size: size)
            } ?? NSFont.systemFont(ofSize: size, weight: weight.fontWeight)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color,
                .paragraphStyle: paragraph, .strokeColor: NSColor.black.withAlphaComponent(0.18), .strokeWidth: -1.5,
                .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0])
            let width = max(1, bounds.maxX - origin.x - 4)
            let height = attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).integral.height
            attributed.draw(with: CGRect(x: origin.x, y: origin.y - height, width: width, height: height),
                            options: [.usesLineFragmentOrigin, .usesFontLeading])
        case let .mosaic(rect):
            let clipped = rect.intersection(bounds)
            guard clipped.width > 1, clipped.height > 1 else { return }
            let smallSize = CGSize(width: max(1, ceil(clipped.width / 14)), height: max(1, ceil(clipped.height / 14)))
            let image = NSImage(cgImage: source, size: CGSize(width: source.width, height: source.height))
            let sourceRect = CGRect(x: clipped.minX / max(bounds.width, 1) * image.size.width,
                                    y: clipped.minY / max(bounds.height, 1) * image.size.height,
                                    width: clipped.width / max(bounds.width, 1) * image.size.width,
                                    height: clipped.height / max(bounds.height, 1) * image.size.height)
            let small = NSImage(size: smallSize)
            small.lockFocus()
            image.draw(in: CGRect(origin: .zero, size: smallSize), from: sourceRect, operation: .sourceOver, fraction: 1)
            small.unlockFocus()
            let previous = NSGraphicsContext.current?.imageInterpolation
            NSGraphicsContext.current?.imageInterpolation = .none
            small.draw(in: clipped, from: CGRect(origin: .zero, size: smallSize), operation: .sourceOver, fraction: 1)
            if let previous { NSGraphicsContext.current?.imageInterpolation = previous }
        }
    }
}
