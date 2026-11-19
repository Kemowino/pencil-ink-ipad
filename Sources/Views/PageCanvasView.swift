import UIKit
import PDFKit

/// Renders one PDF page bitmap + committed vector ink strokes + a 120Hz live stroke layer.
final class PageCanvasView: UIView {
    let pageIndex: Int
    let pageKey: String
    let pageSize: CGSize // PDF points (top-left origin)

    private let pdfImageView = UIImageView()
    private let staticInkView = StaticInkView()
    private let liveShapeLayer = CAShapeLayer()

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

        liveShapeLayer.fillColor = nil
        liveShapeLayer.lineCap = .round
        liveShapeLayer.lineJoin = .round
        liveShapeLayer.contentsScale = UIScreen.main.scale
        layer.addSublayer(liveShapeLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStrokes(_ strokes: [InkStroke]) {
        staticInkView.strokes = strokes
        staticInkView.setNeedsDisplay()
    }

    func updateLiveStroke(points: [InkPoint], color: UIColor, size: CGFloat, isHighlighter: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveShapeLayer.path = StrokeGeometry.buildSmoothPath(from: points)
        liveShapeLayer.strokeColor = color.withAlphaComponent(isHighlighter ? 0.42 : 1.0).cgColor
        liveShapeLayer.lineWidth = size
        CATransaction.commit()
    }

    func clearLiveStroke() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveShapeLayer.path = nil
        CATransaction.commit()
    }

    func applyRenderedImage(_ image: UIImage, zoomScale: CGFloat) {
        pdfImageView.image = image
        renderedZoomScale = zoomScale
        isRendered = true
        // Keep ink crisp at higher zoom levels
        let targetScale = min(UIScreen.main.scale * max(1.0, zoomScale), 3.0)
        if abs(staticInkView.contentScaleFactor - targetScale) > 0.25 {
            staticInkView.contentScaleFactor = targetScale
            staticInkView.setNeedsDisplay()
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
            // Flip UIKit top-left to PDF bottom-left
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
            let box = s.boundingBox().insetBy(dx: -CGFloat(s.size) - 2, dy: -CGFloat(s.size) - 2)
            guard box.intersects(rect) else { continue }
            ctx.setStrokeColor(UIColor(hex: s.color).cgColor)
            ctx.setLineWidth(CGFloat(s.size))
            ctx.addPath(StrokeGeometry.buildSmoothPath(from: s.pts))
            ctx.strokePath()
        }
        ctx.restoreGState()

        // 2. Pen strokes on top
        ctx.setBlendMode(.normal)
        ctx.setAlpha(1.0)
        for s in strokes where s.tool != "highlighter" {
            let box = s.boundingBox().insetBy(dx: -CGFloat(s.size) - 2, dy: -CGFloat(s.size) - 2)
            guard box.intersects(rect) else { continue }
            ctx.setStrokeColor(UIColor(hex: s.color).cgColor)
            ctx.setLineWidth(CGFloat(s.size))
            ctx.addPath(StrokeGeometry.buildSmoothPath(from: s.pts))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
