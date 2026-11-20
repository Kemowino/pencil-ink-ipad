import UIKit
import PDFKit
import CoreImage

struct LaserPoint {
    let x: CGFloat
    let y: CGFloat
    let time: CFTimeInterval
}

/// Renders one PageSlot (PDF page, duplicated PDF page, or paper template) + committed ink + 120Hz live overlay (stroke, eraser ring, laser, or lasso).
final class PageCanvasView: UIView {
    let slot: PageSlot
    var pageIndex: Int { slot.index }
    var pageKey: String { slot.key }
    var pageSize: CGSize { slot.size }

    private let templateView: TemplatePaperView?
    private let hoboView: HobonichiPaperView?
    private let pdfImageView = UIImageView()
    private let staticInkView = StaticInkView()
    private let liveOverlayView = LiveInkOverlayView()

    private(set) var renderedZoomScale: CGFloat = 0
    private(set) var isRendered = false
    private(set) var readingMode: PDFReadingMode = .original
    let isHobonichiSlot: Bool
    var isTemplateOnly: Bool { isHobonichiSlot || slot.effectivePDFPageNumber == nil }
    var renderedImage: UIImage? { pdfImageView.image }

    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    init(
        slot: PageSlot,
        hoboDoc: InkDocument? = nil,
        hoboAllSlots: [PageSlot] = [],
        isHobo: Bool = false,
        readingMode: PDFReadingMode = .original
    ) {
        self.slot = slot
        self.readingMode = readingMode
        let hoboKind = HobonichiEngine.slotKind(for: slot, isHobo: isHobo)
        self.isHobonichiSlot = (hoboKind != nil)
        let hv: HobonichiPaperView? = (hoboKind != nil)
            ? HobonichiPaperView(slot: slot, doc: hoboDoc ?? InkDocument.empty(name: ""), allSlots: hoboAllSlots, isHobo: isHobo)
            : nil
        let tplView: TemplatePaperView? = (hv == nil && slot.effectivePDFPageNumber == nil)
            ? TemplatePaperView(template: slot.template, readingMode: readingMode)
            : nil
        self.hoboView = hv
        self.templateView = tplView
        super.init(frame: CGRect(origin: .zero, size: slot.size))
        if hv != nil {
            backgroundColor = HobonichiEngine.creamColor
        } else {
            backgroundColor = Self.paperBackdropColor(for: readingMode)
        }
        staticInkView.smartDarkInk = (!isHobonichiSlot && readingMode == .dark)
        liveOverlayView.smartDarkInk = (!isHobonichiSlot && readingMode == .dark)
        layer.cornerRadius = 3
        layer.masksToBounds = true
        isUserInteractionEnabled = false

        if let hv = hv {
            hv.frame = bounds
            hv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(hv)
            isRendered = true
            renderedZoomScale = 1.0
        } else if let tv = tplView {
            tv.frame = bounds
            tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(tv)
            isRendered = true
            renderedZoomScale = 1.0
        } else {
            pdfImageView.frame = bounds
            pdfImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pdfImageView.contentMode = .scaleToFill
            addSubview(pdfImageView)
        }

        staticInkView.frame = bounds
        staticInkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        staticInkView.backgroundColor = .clear
        staticInkView.isOpaque = false
        staticInkView.pageSize = slot.size
        addSubview(staticInkView)

        liveOverlayView.frame = bounds
        liveOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        liveOverlayView.backgroundColor = .clear
        liveOverlayView.isOpaque = false
        addSubview(liveOverlayView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStrokes(_ strokes: [InkStroke], hiddenIDs: Set<String> = []) {
        staticInkView.strokes = strokes
        staticInkView.hiddenStrokeIDs = hiddenIDs
        staticInkView.setNeedsDisplay()
    }

    func setTextBoxes(_ boxes: [InkTextBox], hiddenID: String? = nil) {
        staticInkView.textBoxes = boxes
        staticInkView.hiddenTextBoxID = hiddenID
        staticInkView.setNeedsDisplay()
    }

    func setHiddenTextBoxID(_ id: String?) {
        staticInkView.hiddenTextBoxID = id
        staticInkView.setNeedsDisplay()
    }

    func setHiddenStrokeIDs(_ ids: Set<String>) {
        staticInkView.hiddenStrokeIDs = ids
        staticInkView.setNeedsDisplay()
    }

    func updateLiveStroke(
        points: [InkPoint],
        color: UIColor,
        size: CGFloat,
        tool: String,
        style: String,
        straight: Bool,
        isSmartShape: Bool
    ) {
        liveOverlayView.mode = .stroke(
            points: points,
            color: color,
            size: size,
            tool: tool,
            style: style,
            straight: straight,
            isSmartShape: isSmartShape
        )
        liveOverlayView.setNeedsDisplay()
    }

    func updateEraserRing(center: CGPoint?, radius: CGFloat, zoomScale: CGFloat) {
        if let c = center {
            liveOverlayView.mode = .eraserRing(center: c, radius: radius, zoomScale: zoomScale)
        } else {
            liveOverlayView.mode = .none
        }
        liveOverlayView.setNeedsDisplay()
    }

    func updateLaser(points: [LaserPoint], color: UIColor, showTrail: Bool, zoomScale: CGFloat, now: CFTimeInterval) {
        if points.isEmpty {
            liveOverlayView.mode = .none
        } else {
            liveOverlayView.mode = .laser(points: points, color: color, showTrail: showTrail, zoomScale: zoomScale, now: now)
        }
        liveOverlayView.setNeedsDisplay()
    }

    func updateLasso(selection: LassoSelection?, zoomScale: CGFloat) {
        guard let sel = selection else {
            liveOverlayView.mode = .none
            liveOverlayView.setNeedsDisplay()
            return
        }
        if sel.mode == .drawing {
            liveOverlayView.mode = .lassoDrawing(poly: sel.poly, zoomScale: zoomScale)
        } else if !sel.strokes.isEmpty {
            liveOverlayView.mode = .lassoSelected(selection: sel, zoomScale: zoomScale)
        } else {
            liveOverlayView.mode = .none
        }
        liveOverlayView.setNeedsDisplay()
    }

    func clearLiveOverlay() {
        liveOverlayView.mode = .none
        liveOverlayView.setNeedsDisplay()
    }

    func applyRenderedImage(_ image: UIImage, zoomScale: CGFloat) {
        if !isTemplateOnly {
            pdfImageView.image = image
        }
        renderedZoomScale = zoomScale
        isRendered = true
        refreshVectorScale(for: zoomScale)
    }

    func refreshVectorScale(for zoomScale: CGFloat) {
        let screenScale = max(1.0, traitCollection.displayScale > 0 ? traitCollection.displayScale : 2.0)
        let targetScale = min(screenScale * max(1.0, zoomScale), 3.0)
        if abs(staticInkView.contentScaleFactor - targetScale) > 0.25 {
            staticInkView.contentScaleFactor = targetScale
            staticInkView.setNeedsDisplay()
            liveOverlayView.contentScaleFactor = min(screenScale * max(1.0, zoomScale), 2.5)
        }
        if let tv = templateView, abs(tv.contentScaleFactor - targetScale) > 0.25 {
            tv.contentScaleFactor = targetScale
            tv.setNeedsDisplay()
        }
        if let hv = hoboView, abs(hv.contentScaleFactor - targetScale) > 0.25 {
            hv.contentScaleFactor = targetScale
            hv.setNeedsDisplay()
        }
        if isTemplateOnly {
            renderedZoomScale = zoomScale
            isRendered = true
        }
    }

    func setReadingMode(_ mode: PDFReadingMode) {
        guard readingMode != mode else { return }
        readingMode = mode
        if !isHobonichiSlot {
            backgroundColor = Self.paperBackdropColor(for: mode)
            staticInkView.smartDarkInk = (mode == .dark)
            staticInkView.setNeedsDisplay()
            liveOverlayView.smartDarkInk = (mode == .dark)
            if let tv = templateView {
                tv.readingMode = mode
                tv.setNeedsDisplay()
            } else {
                evictBitmap()
            }
        }
    }

    static func paperBackdropColor(for mode: PDFReadingMode) -> UIColor {
        switch mode {
        case .original: return .white
        case .dark: return UIColor(red: 0.11, green: 0.115, blue: 0.13, alpha: 1.0)
        case .sepia: return UIColor(red: 0.965, green: 0.935, blue: 0.87, alpha: 1.0)
        }
    }

    static func displayColor(for hex: String, smartDark: Bool) -> UIColor {
        let base = UIColor(hex: hex)
        guard smartDark else { return base }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard base.getRed(&r, green: &g, blue: &b, alpha: &a) else { return base }
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        if lum < 0.28 {
            return UIColor(red: 0.93, green: 0.94, blue: 0.97, alpha: a)
        }
        return base
    }

    static func applyReadingFilter(to image: UIImage, mode: PDFReadingMode) -> UIImage {
        guard mode != .original, let cgImg = image.cgImage else { return image }
        switch mode {
        case .original:
            return image
        case .dark:
            let input = CIImage(cgImage: cgImg)
            guard let invert = CIFilter(name: "CIColorInvert") else { return image }
            invert.setValue(input, forKey: kCIInputImageKey)
            guard let inverted = invert.outputImage else { return image }
            let finalCI: CIImage
            if let hue = CIFilter(name: "CIHueAdjust") {
                hue.setValue(inverted, forKey: kCIInputImageKey)
                hue.setValue(Float.pi, forKey: kCIInputAngleKey)
                finalCI = hue.outputImage ?? inverted
            } else {
                finalCI = inverted
            }
            // Gently lift pure #000000 black background to comfortable OLED dark slate
            let lifted: CIImage
            if let tone = CIFilter(name: "CIColorControls") {
                tone.setValue(finalCI, forKey: kCIInputImageKey)
                tone.setValue(0.06, forKey: kCIInputBrightnessKey)
                tone.setValue(0.92, forKey: kCIInputContrastKey)
                lifted = tone.outputImage ?? finalCI
            } else {
                lifted = finalCI
            }
            if let outCG = sharedCIContext.createCGImage(lifted, from: input.extent) {
                return UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation)
            }
            return image
        case .sepia:
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
            return renderer.image { ctx in
                image.draw(at: .zero)
                ctx.cgContext.setBlendMode(.multiply)
                UIColor(red: 0.965, green: 0.935, blue: 0.865, alpha: 1.0).setFill()
                ctx.cgContext.fill(CGRect(origin: .zero, size: image.size))
            }
        }
    }

    func evictBitmap() {
        guard !isTemplateOnly else { return }
        pdfImageView.image = nil
        renderedZoomScale = 0
        isRendered = false
    }

    static func normalizedPageSize(for page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        let rot = ((page.rotation % 360) + 360) % 360
        if rot == 90 || rot == 270 {
            return CGSize(width: box.height, height: box.width)
        }
        return box.size
    }

    static func renderSlotBackground(
        slot: PageSlot,
        pdfDoc: PDFDocument?,
        zoomScale: CGFloat,
        maxPixels: CGFloat = 6_000_000,
        readingMode: PDFReadingMode = .original
    ) -> UIImage {
        let pageSize = slot.size
        let dpr = min(UIScreen.main.scale, 2.0)
        let desiredScale = max(0.35, min(zoomScale * dpr, 3.0))
        let rawPx = (pageSize.width * desiredScale) * (pageSize.height * desiredScale)
        let finalScale = rawPx > maxPixels ? desiredScale * sqrt(maxPixels / rawPx) : desiredScale

        let format = UIGraphicsImageRendererFormat()
        format.scale = finalScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pageSize, format: format)
        let baseImg = renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            drawSlotBackground(slot: slot, pdfDoc: pdfDoc, in: ctx)
        }
        return applyReadingFilter(to: baseImg, mode: readingMode)
    }

    func updateHobonichiData(doc: InkDocument, allSlots: [PageSlot]) {
        guard let hv = hoboView else { return }
        hv.doc = doc
        hv.allSlots = allSlots
        hv.setNeedsDisplay()
    }

    static func drawSlotBackground(
        slot: PageSlot,
        pdfDoc: PDFDocument?,
        in ctx: CGContext,
        hoboDoc: InkDocument? = nil,
        hoboAllSlots: [PageSlot] = [],
        isHobo: Bool = false
    ) {
        ctx.saveGState()
        if isHobo, HobonichiEngine.slotKind(for: slot, isHobo: true) != nil {
            HobonichiEngine.drawSpread(in: ctx, slot: slot, doc: hoboDoc ?? InkDocument.empty(name: ""), allSlots: hoboAllSlots, isHobo: true)
        } else if let pdfN = slot.effectivePDFPageNumber, let page = pdfDoc?.page(at: pdfN - 1) {
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: slot.size))
            ctx.translateBy(x: 0, y: slot.size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.concatenate(page.transform(for: .cropBox))
            page.draw(with: .cropBox, to: ctx)
        } else {
            slot.template.draw(in: ctx, size: slot.size)
        }
        ctx.restoreGState()
    }

    static func drawStrokes(
        _ strokes: [InkStroke],
        in ctx: CGContext,
        clipRect: CGRect? = nil,
        hiddenIDs: Set<String> = [],
        smartDarkInk: Bool = false
    ) {
        guard !strokes.isEmpty else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // 1. Highlighters first (multiply on light/sepia paper, screen/normal translucent on dark paper)
        ctx.saveGState()
        ctx.setBlendMode(smartDarkInk ? .screen : .multiply)
        ctx.setAlpha(smartDarkInk ? 0.34 : 0.42)
        for s in strokes where s.tool == "highlighter" {
            if hiddenIDs.contains(s.id) { continue }
            if let rect = clipRect {
                let pad = CGFloat(s.size) * 1.5 + 4
                guard s.boundingBox().insetBy(dx: -pad, dy: -pad).intersects(rect) else { continue }
            }
            StrokeGeometry.drawCommittedStroke(s, in: ctx)
        }
        ctx.restoreGState()

        // 2. Pen strokes on top
        ctx.setBlendMode(.normal)
        ctx.setAlpha(1.0)
        for s in strokes where s.tool != "highlighter" {
            if hiddenIDs.contains(s.id) { continue }
            if let rect = clipRect {
                let pad = CGFloat(s.size) * 1.8 + 4
                guard s.boundingBox().insetBy(dx: -pad, dy: -pad).intersects(rect) else { continue }
            }
            if smartDarkInk {
                let liftedColor = displayColor(for: s.color, smartDark: true)
                let liftedHex = liftedColor.toHexString()
                if liftedHex != s.color {
                    var copy = s
                    copy.color = liftedHex
                    StrokeGeometry.drawCommittedStroke(copy, in: ctx)
                    continue
                }
            }
            StrokeGeometry.drawCommittedStroke(s, in: ctx)
        }
        ctx.restoreGState()
    }

    /// Renders a complete composite image (PDF/template + ink strokes) for thumbnails or PNG sharing.
    static func drawTextBoxes(
        _ boxes: [InkTextBox],
        in ctx: CGContext,
        hiddenID: String? = nil,
        smartDarkInk: Bool = false
    ) {
        guard !boxes.isEmpty else { return }
        ctx.saveGState()
        UIGraphicsPushContext(ctx)
        defer {
            UIGraphicsPopContext()
            ctx.restoreGState()
        }

        for box in boxes {
            if box.id == hiddenID { continue }
            let trimmed = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let rect = box.measuredRect()

            if let bgHex = box.bgColor, !bgHex.isEmpty {
                let bgCol = UIColor(hex: bgHex).withAlphaComponent(smartDarkInk ? 0.24 : 0.85)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 5)
                bgCol.setFill()
                path.fill()
            }

            let textColor = displayColor(for: box.color, smartDark: smartDarkInk)
            let font = box.resolvedUIFont()
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: para
            ]
            let drawRect = rect.insetBy(dx: 6, dy: 4)
            (box.text as NSString).draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
        }
    }

    static func renderCompositeImage(
        slot: PageSlot,
        pdfDoc: PDFDocument?,
        strokes: [InkStroke],
        textBoxes: [InkTextBox] = [],
        scale: CGFloat,
        hoboDoc: InkDocument? = nil,
        hoboAllSlots: [PageSlot] = [],
        isHobo: Bool = false
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(0.25, scale)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: slot.size, format: format)
        return renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            drawSlotBackground(slot: slot, pdfDoc: pdfDoc, in: ctx, hoboDoc: hoboDoc, hoboAllSlots: hoboAllSlots, isHobo: isHobo)
            drawStrokes(strokes, in: ctx)
            drawTextBoxes(textBoxes, in: ctx)
        }
    }
}

private final class StaticInkView: UIView {
    var pageSize: CGSize = .zero
    var strokes: [InkStroke] = []
    var hiddenStrokeIDs: Set<String> = []
    var textBoxes: [InkTextBox] = []
    var hiddenTextBoxID: String? = nil
    var smartDarkInk: Bool = false

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if !strokes.isEmpty {
            PageCanvasView.drawStrokes(strokes, in: ctx, clipRect: rect, hiddenIDs: hiddenStrokeIDs, smartDarkInk: smartDarkInk)
        }
        if !textBoxes.isEmpty {
            PageCanvasView.drawTextBoxes(textBoxes, in: ctx, hiddenID: hiddenTextBoxID, smartDarkInk: smartDarkInk)
        }
    }
}

private final class LiveInkOverlayView: UIView {
    enum Mode {
        case none
        case stroke(points: [InkPoint], color: UIColor, size: CGFloat, tool: String, style: String, straight: Bool, isSmartShape: Bool)
        case eraserRing(center: CGPoint, radius: CGFloat, zoomScale: CGFloat)
        case laser(points: [LaserPoint], color: UIColor, showTrail: Bool, zoomScale: CGFloat, now: CFTimeInterval)
        case lassoDrawing(poly: [CGPoint], zoomScale: CGFloat)
        case lassoSelected(selection: LassoSelection, zoomScale: CGFloat)
    }

    var mode: Mode = .none
    var smartDarkInk: Bool = false

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        switch mode {
        case .none:
            return
        case let .stroke(points, color, size, tool, style, straight, isSmartShape):
            ctx.saveGState()
            let drawCol: UIColor
            if tool == "highlighter" {
                ctx.setBlendMode(smartDarkInk ? .screen : .multiply)
                ctx.setAlpha(smartDarkInk ? 0.34 : 0.42)
                drawCol = color
            } else if smartDarkInk {
                drawCol = PageCanvasView.displayColor(for: color.toHexString(), smartDark: true)
            } else {
                drawCol = color
            }
            StrokeGeometry.drawStroke(
                in: ctx,
                points: points,
                color: drawCol,
                baseSize: size,
                tool: tool,
                style: style,
                straight: straight,
                isSmartShape: isSmartShape
            )
            ctx.restoreGState()

        case let .eraserRing(center, radius, zoomScale):
            ctx.saveGState()
            let r = max(2, radius)
            let ringRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(UIColor(white: 0.45, alpha: 0.14).cgColor)
            ctx.fillEllipse(in: ringRect)
            ctx.setStrokeColor(UIColor(white: 0.35, alpha: 0.9).cgColor)
            ctx.setLineWidth(1.4 / max(0.5, zoomScale))
            ctx.strokeEllipse(in: ringRect)
            ctx.restoreGState()

        case let .laser(points, color, showTrail, zoomScale, now):
            let sc = max(0.5, zoomScale)
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if showTrail && points.count >= 2 {
                for i in 1..<points.count {
                    let a = points[i - 1], b = points[i]
                    let age = now - b.time
                    let alpha = CGFloat(max(0.0, 1.0 - age / 0.95))
                    guard alpha > 0.01 else { continue }
                    ctx.setStrokeColor(color.withAlphaComponent(alpha * 0.38).cgColor)
                    ctx.setLineWidth(9.0 / sc)
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: a.x, y: a.y))
                    ctx.addLine(to: CGPoint(x: b.x, y: b.y))
                    ctx.strokePath()

                    ctx.setStrokeColor(UIColor.white.withAlphaComponent(alpha).cgColor)
                    ctx.setLineWidth(2.6 / sc)
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: a.x, y: a.y))
                    ctx.addLine(to: CGPoint(x: b.x, y: b.y))
                    ctx.strokePath()
                }
            }
            if let tip = points.last, now - tip.time < 0.25 {
                let outerR = 6.5 / sc
                let innerR = 2.8 / sc
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: CGRect(x: tip.x - outerR, y: tip.y - outerR, width: outerR * 2, height: outerR * 2))
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fillEllipse(in: CGRect(x: tip.x - innerR, y: tip.y - innerR, width: innerR * 2, height: innerR * 2))
            }
            ctx.restoreGState()

        case let .lassoDrawing(poly, zoomScale):
            guard poly.count >= 2 else { return }
            let sc = max(0.5, zoomScale)
            ctx.saveGState()
            let path = CGMutablePath()
            path.move(to: poly[0])
            for i in 1..<poly.count { path.addLine(to: poly[i]) }
            ctx.addPath(path)
            ctx.setFillColor(UIColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 0.09).cgColor)
            ctx.fillPath()

            ctx.addPath(path)
            ctx.setStrokeColor(UIColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1.0).cgColor)
            ctx.setLineWidth(1.8 / sc)
            ctx.setLineDash(phase: 0, lengths: [6.0 / sc, 4.0 / sc])
            ctx.strokePath()
            ctx.restoreGState()

        case let .lassoSelected(sel, zoomScale):
            let sc = max(0.5, zoomScale)
            // 1. Render transformed strokes live
            ctx.saveGState()
            ctx.translateBy(x: sel.pivot.x + sel.tx, y: sel.pivot.y + sel.ty)
            if sel.rotation != 0 { ctx.rotate(by: sel.rotation) }
            ctx.scaleBy(x: sel.scale, y: sel.scale)
            ctx.translateBy(x: -sel.pivot.x, y: -sel.pivot.y)
            PageCanvasView.drawStrokes(sel.strokes, in: ctx)
            ctx.restoreGState()

            // 2. Render selection dashed box + 4 scale handles + top rotation handle
            let h = sel.handles(zoomScale: sc)
            let accent = UIColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1.0)
            ctx.saveGState()
            if sel.rotation != 0 {
                ctx.translateBy(x: h.cx, y: h.cy)
                ctx.rotate(by: sel.rotation)
                ctx.translateBy(x: -h.cx, y: -h.cy)
            }
            let boxRect = CGRect(x: h.bx0, y: h.by0, width: h.bx1 - h.bx0, height: h.by1 - h.by0)
            ctx.setFillColor(accent.withAlphaComponent(0.05).cgColor)
            ctx.fill(boxRect)

            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.6 / sc)
            ctx.setLineDash(phase: 0, lengths: [5.0 / sc, 4.0 / sc])
            ctx.stroke(boxRect)

            // Rotation stem + handle
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.move(to: CGPoint(x: h.cx, y: h.by0))
            ctx.addLine(to: CGPoint(x: h.cx, y: h.rotY))
            ctx.strokePath()

            let rHandle = 5.4 / sc
            let rotRect = CGRect(x: h.cx - rHandle, y: h.rotY - rHandle, width: rHandle * 2, height: rHandle * 2)
            ctx.setFillColor(accent.cgColor)
            ctx.fillEllipse(in: rotRect)
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(1.5 / sc)
            ctx.strokeEllipse(in: rotRect)

            // 4 corner scale handles
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.8 / sc)
            for c in h.corners {
                let cr = CGRect(x: c.x - rHandle, y: c.y - rHandle, width: rHandle * 2, height: rHandle * 2)
                ctx.fillEllipse(in: cr)
                ctx.strokeEllipse(in: cr)
            }
            ctx.restoreGState()
        }
    }
}


private final class TemplatePaperView: UIView {
    let template: PaperTemplate
    var readingMode: PDFReadingMode

    init(template: PaperTemplate, readingMode: PDFReadingMode = .original) {
        self.template = template
        self.readingMode = readingMode
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = PageCanvasView.paperBackdropColor(for: readingMode)
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        template.draw(in: ctx, size: bounds.size)
        if readingMode == .sepia {
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            UIColor(red: 0.965, green: 0.935, blue: 0.865, alpha: 1.0).setFill()
            ctx.fill(bounds)
            ctx.restoreGState()
        } else if readingMode == .dark {
            ctx.saveGState()
            ctx.setFillColor(red: 0.115, green: 0.12, blue: 0.135, alpha: 1.0)
            ctx.fill(bounds)
            let w = bounds.width, h = bounds.height
            switch template {
            case .blank:
                break
            case .lined:
                ctx.setStrokeColor(red: 0.30, green: 0.36, blue: 0.45, alpha: 0.7)
                ctx.setLineWidth(0.8)
                var y: CGFloat = 68
                while y <= h - 42 {
                    ctx.move(to: CGPoint(x: 36, y: y)); ctx.addLine(to: CGPoint(x: w - 36, y: y))
                    y += 28
                }
                ctx.strokePath()
            case .grid:
                ctx.setStrokeColor(red: 0.25, green: 0.28, blue: 0.34, alpha: 0.8)
                ctx.setLineWidth(0.6)
                var x: CGFloat = 36
                while x <= w - 36 { ctx.move(to: CGPoint(x: x, y: 36)); ctx.addLine(to: CGPoint(x: x, y: h - 36)); x += 18 }
                var y: CGFloat = 36
                while y <= h - 36 { ctx.move(to: CGPoint(x: 36, y: y)); ctx.addLine(to: CGPoint(x: w - 36, y: y)); y += 18 }
                ctx.strokePath()
            case .dot:
                ctx.setFillColor(red: 0.44, green: 0.47, blue: 0.54, alpha: 0.85)
                var x: CGFloat = 36
                while x <= w - 36 {
                    var y: CGFloat = 36
                    while y <= h - 36 {
                        ctx.fillEllipse(in: CGRect(x: x - 1.25, y: y - 1.25, width: 2.5, height: 2.5))
                        y += 18
                    }
                    x += 18
                }
            case .cornell:
                ctx.setStrokeColor(red: 0.30, green: 0.36, blue: 0.45, alpha: 0.7)
                ctx.setLineWidth(0.75)
                var y: CGFloat = 112
                while y <= h - 155 { ctx.move(to: CGPoint(x: 175, y: y)); ctx.addLine(to: CGPoint(x: w - 36, y: y)); y += 26 }
                ctx.strokePath()
                ctx.setStrokeColor(red: 0.72, green: 0.36, blue: 0.36, alpha: 0.85)
                ctx.setLineWidth(1.0)
                ctx.move(to: CGPoint(x: 36, y: 84)); ctx.addLine(to: CGPoint(x: w - 36, y: 84))
                ctx.move(to: CGPoint(x: 175, y: 84)); ctx.addLine(to: CGPoint(x: 175, y: h - 140))
                ctx.move(to: CGPoint(x: 36, y: h - 140)); ctx.addLine(to: CGPoint(x: w - 36, y: h - 140))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }
}


private final class HobonichiPaperView: UIView {
    let slot: PageSlot
    var doc: InkDocument
    var allSlots: [PageSlot]
    let isHobo: Bool

    init(slot: PageSlot, doc: InkDocument, allSlots: [PageSlot], isHobo: Bool) {
        self.slot = slot
        self.doc = doc
        self.allSlots = allSlots
        self.isHobo = isHobo
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = HobonichiEngine.creamColor
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        HobonichiEngine.drawSpread(in: ctx, slot: slot, doc: doc, allSlots: allSlots, isHobo: isHobo)
    }
}
