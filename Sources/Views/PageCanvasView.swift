import UIKit
import PDFKit

struct LaserPoint {
    let x: CGFloat
    let y: CGFloat
    let time: CFTimeInterval
}

/// Renders one PDF page bitmap + committed vector ink strokes + a 120Hz live overlay (pen, highlighter, eraser ring, laser trail).
final class PageCanvasView: UIView {
    let pageIndex: Int
    let pageKey: String
    let pageSize: CGSize // PDF points (top-left origin)

    private let pdfImageView = UIImageView()
    private let staticInkView = StaticInkView()
    private let liveOverlayView = LiveInkOverlayView()

    private(set) var renderedZoomScale: CGFloat = 0
    private(set) var isRendered = false

    init(pageIndex: Int, pageSize: CGSize) {
        self.pageIndex = pageIndex
        self.pageKey = String(pageIndex + 1)
        self.pageSize = pageSize
        super.init(frame: CGRect(origin: .zero, size: pageSize))
        backgroundColor = .white
        layer.cornerRadius = 3
        layer.masksToBounds = true
        isUserInteractionEnabled = false

        pdfImageView.frame = bounds
        pdfImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfImageView.contentMode = .scaleToFill
        addSubview(pdfImageView)

        staticInkView.frame = bounds
        staticInkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        staticInkView.backgroundColor = .clear
        staticInkView.isOpaque = false
        staticInkView.pageSize = pageSize
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

    func setStrokes(_ strokes: [InkStroke]) {
        staticInkView.strokes = strokes
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

    func clearLiveOverlay() {
        liveOverlayView.mode = .none
        liveOverlayView.setNeedsDisplay()
    }

    func applyRenderedImage(_ image: UIImage, zoomScale: CGFloat) {
        pdfImageView.image = image
        renderedZoomScale = zoomScale
        isRendered = true
        let targetScale = min(UIScreen.main.scale * max(1.0, zoomScale), 3.0)
        if abs(staticInkView.contentScaleFactor - targetScale) > 0.25 {
            staticInkView.contentScaleFactor = targetScale
            staticInkView.setNeedsDisplay()
            liveOverlayView.contentScaleFactor = min(UIScreen.main.scale * max(1.0, zoomScale), 2.5)
        }
    }

    func evictBitmap() {
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

    static func renderPage(_ page: PDFPage, pageSize: CGSize, zoomScale: CGFloat) -> UIImage {
        let dpr = min(UIScreen.main.scale, 2.0)
        let maxPixels: CGFloat = 6_000_000
        let desiredScale = max(1.0, min(zoomScale * dpr, 3.0))
        let rawPx = (pageSize.width * desiredScale) * (pageSize.height * desiredScale)
        let finalScale = rawPx > maxPixels ? desiredScale * sqrt(maxPixels / rawPx) : desiredScale

        let format = UIGraphicsImageRendererFormat()
        format.scale = finalScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pageSize, format: format)
        return renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            ctx.saveGState()
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: pageSize))
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.concatenate(page.transform(for: .cropBox))
            page.draw(with: .cropBox, to: ctx)
            ctx.restoreGState()
        }
    }
}

private final class StaticInkView: UIView {
    var pageSize: CGSize = .zero
    var strokes: [InkStroke] = []

    override func draw(_ rect: CGRect) {
        guard !strokes.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // 1. Highlighters first (multiply blend, 0.42 alpha)
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setAlpha(0.42)
        for s in strokes where s.tool == "highlighter" {
            let pad = CGFloat(s.size) * 1.5 + 4
            let box = s.boundingBox().insetBy(dx: -pad, dy: -pad)
            guard box.intersects(rect) else { continue }
            StrokeGeometry.drawCommittedStroke(s, in: ctx)
        }
        ctx.restoreGState()

        // 2. Pen strokes on top
        ctx.setBlendMode(.normal)
        ctx.setAlpha(1.0)
        for s in strokes where s.tool != "highlighter" {
            let pad = CGFloat(s.size) * 1.8 + 4
            let box = s.boundingBox().insetBy(dx: -pad, dy: -pad)
            guard box.intersects(rect) else { continue }
            StrokeGeometry.drawCommittedStroke(s, in: ctx)
        }
        ctx.restoreGState()
    }
}

private final class LiveInkOverlayView: UIView {
    enum Mode {
        case none
        case stroke(points: [InkPoint], color: UIColor, size: CGFloat, tool: String, style: String, straight: Bool, isSmartShape: Bool)
        case eraserRing(center: CGPoint, radius: CGFloat, zoomScale: CGFloat)
        case laser(points: [LaserPoint], color: UIColor, showTrail: Bool, zoomScale: CGFloat, now: CFTimeInterval)
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
        }
    }
}
