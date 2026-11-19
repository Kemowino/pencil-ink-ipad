import UIKit
import PDFKit

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
    let isHobonichiSlot: Bool
    var isTemplateOnly: Bool { isHobonichiSlot || slot.effectivePDFPageNumber == nil }
    var renderedImage: UIImage? { pdfImageView.image }

    init(slot: PageSlot, hoboDoc: InkDocument? = nil, hoboAllSlots: [PageSlot] = [], isHobo: Bool = false) {
        self.slot = slot
        let hoboKind = HobonichiEngine.slotKind(for: slot, isHobo: isHobo)
        self.isHobonichiSlot = (hoboKind != nil)
        let hv: HobonichiPaperView? = (hoboKind != nil)
            ? HobonichiPaperView(slot: slot, doc: hoboDoc ?? InkDocument.empty(name: ""), allSlots: hoboAllSlots, isHobo: isHobo)
            : nil
        let tplView: TemplatePaperView? = (hv == nil && slot.effectivePDFPageNumber == nil)
            ? TemplatePaperView(template: slot.template)
            : nil
        self.hoboView = hv
        self.templateView = tplView
        super.init(frame: CGRect(origin: .zero, size: slot.size))
        backgroundColor = (hv != nil) ? HobonichiEngine.creamColor : .white
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
        let targetScale = min(UIScreen.main.scale * max(1.0, zoomScale), 3.0)
        if abs(staticInkView.contentScaleFactor - targetScale) > 0.25 {
            staticInkView.contentScaleFactor = targetScale
            staticInkView.setNeedsDisplay()
            liveOverlayView.contentScaleFactor = min(UIScreen.main.scale * max(1.0, zoomScale), 2.5)
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

    static func renderSlotBackground(slot: PageSlot, pdfDoc: PDFDocument?, zoomScale: CGFloat, maxPixels: CGFloat = 6_000_000) -> UIImage {
        let pageSize = slot.size
        let dpr = min(UIScreen.main.scale, 2.0)
        let desiredScale = max(0.35, min(zoomScale * dpr, 3.0))
        let rawPx = (pageSize.width * desiredScale) * (pageSize.height * desiredScale)
        let finalScale = rawPx > maxPixels ? desiredScale * sqrt(maxPixels / rawPx) : desiredScale

        let format = UIGraphicsImageRendererFormat()
        format.scale = finalScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pageSize, format: format)
        return renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            drawSlotBackground(slot: slot, pdfDoc: pdfDoc, in: ctx)
        }
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

    static func drawStrokes(_ strokes: [InkStroke], in ctx: CGContext, clipRect: CGRect? = nil, hiddenIDs: Set<String> = []) {
        guard !strokes.isEmpty else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // 1. Highlighters first (multiply blend, 0.42 alpha)
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setAlpha(0.42)
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
            StrokeGeometry.drawCommittedStroke(s, in: ctx)
        }
        ctx.restoreGState()
    }

    /// Renders a complete composite image (PDF/template + ink strokes) for thumbnails or PNG sharing.
    static func renderCompositeImage(
        slot: PageSlot,
        pdfDoc: PDFDocument?,
        strokes: [InkStroke],
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
        }
    }
}

private final class StaticInkView: UIView {
    var pageSize: CGSize = .zero
    var strokes: [InkStroke] = []
    var hiddenStrokeIDs: Set<String> = []

    override func draw(_ rect: CGRect) {
        guard !strokes.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
        PageCanvasView.drawStrokes(strokes, in: ctx, clipRect: rect, hiddenIDs: hiddenStrokeIDs)
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

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        switch mode {
        case .none:
            return
        case let .stroke(points, color, size, tool, style, straight, isSmartShape):
            ctx.saveGState()
            if tool == "highlighter" {
                ctx.setBlendMode(.multiply)
                ctx.setAlpha(0.42)
            }
            StrokeGeometry.drawStroke(
                in: ctx,
                points: points,
                color: color,
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

    init(template: PaperTemplate) {
        self.template = template
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = .white
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        template.draw(in: ctx, size: bounds.size)
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
