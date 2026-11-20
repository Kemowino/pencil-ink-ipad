import UIKit
import PDFKit
import CoreImage
import QuartzCore

struct LaserPoint {
    let x: CGFloat
    let y: CGFloat
    let time: CFTimeInterval
}

/// Renders one PageSlot (PDF page, duplicated PDF page, or paper template) + committed ink + live overlay.
/// Preview-Class Optimization:
/// - Direct raw `CALayer` (`pdfContentLayer`) instead of `UIImageView` (zero `invalidateIntrinsicContentSize` or UIKit layout cascades!)
/// - Direct native-GPU 32-bit `BGRX` `CGBitmapContext` inside `autoreleasepool` (1 buffer, zero `preparingForDisplay()` double copy, zero ICC profile conversion!)
/// - `staticInkView` and `liveOverlayView` stay `isHidden = true` when empty (0 bytes VRAM & 0 GPU alpha-blend cost!)
/// - Recyclable via `configure(...)` + `prepareForReuse()` with `CATransaction.setDisableActions(true)`.
final class PageCanvasView: UIView {
    private(set) var slot: PageSlot
    var pageIndex: Int { slot.index }
    var pageKey: String { slot.key }
    var pageSize: CGSize { slot.size }

    private var templateView: TemplatePaperView?
    private var hoboView: HobonichiPaperView?
    private let pdfContentLayer = CALayer()
    private let staticInkView = StaticInkView()
    private let liveOverlayView = LiveInkOverlayView()

    private(set) var renderedZoomScale: CGFloat = 0
    private(set) var isRendered = false
    private(set) var readingMode: PDFReadingMode = .original
    private(set) var isHobonichiSlot: Bool
    var isTemplateOnly: Bool { isHobonichiSlot || slot.effectivePDFPageNumber == nil }
    var isRecyclablePDFPage: Bool { !isTemplateOnly }
    private(set) var renderedCGImage: CGImage? = nil

    /// Tagged sRGB avoids WindowServer DeviceRGB->Display-P3 ColorSync shader passes on macOS!
    private static let sharedSRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let nativeBGRXBitmapInfo: UInt32 =
        CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue

    private static let noLayerActions: [String: CAAction] = [
        "contents": NSNull(),
        "bounds": NSNull(),
        "position": NSNull(),
        "hidden": NSNull(),
        "opacity": NSNull(),
        "backgroundColor": NSNull()
    ]

    /// Lazily created ONLY if the user switches to Dark Paper mode (0 GPU/Metal cost in Original & Sepia modes!).
    private static var lazyCIContext: CIContext?
    private static let ciContextLock = NSLock()
    private static func getCIContext() -> CIContext {
        ciContextLock.lock()
        defer { ciContextLock.unlock() }
        if let ctx = lazyCIContext { return ctx }
        let ctx = CIContext(options: [
            .useSoftwareRenderer: false,
            .priorityRequestLow: true,
            .cacheIntermediates: false
        ])
        lazyCIContext = ctx
        return ctx
    }

    init(
        slot: PageSlot,
        hoboDoc: InkDocument? = nil,
        hoboAllSlots: [PageSlot] = [],
        isHobo: Bool = false,
        readingMode: PDFReadingMode = .original
    ) {
        self.slot = slot
        self.readingMode = readingMode
        self.isHobonichiSlot = (HobonichiEngine.slotKind(for: slot, isHobo: isHobo) != nil)
        super.init(frame: CGRect(origin: .zero, size: slot.size))

        #if targetEnvironment(macCatalyst)
        layer.cornerRadius = 0
        layer.masksToBounds = false
        #else
        layer.cornerRadius = 2.5
        layer.masksToBounds = true
        #endif
        layer.actions = Self.noLayerActions
        layer.allowsEdgeAntialiasing = false
        layer.allowsGroupOpacity = false
        isOpaque = true
        isUserInteractionEnabled = false

        pdfContentLayer.frame = bounds
        pdfContentLayer.isOpaque = true
        pdfContentLayer.allowsEdgeAntialiasing = false
        pdfContentLayer.allowsGroupOpacity = false
        pdfContentLayer.contentsGravity = .resize
        pdfContentLayer.magnificationFilter = .linear
        pdfContentLayer.minificationFilter = .linear
        pdfContentLayer.actions = Self.noLayerActions
        layer.addSublayer(pdfContentLayer)

        staticInkView.frame = bounds
        staticInkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        staticInkView.backgroundColor = .clear
        staticInkView.isOpaque = false
        staticInkView.isHidden = true
        addSubview(staticInkView)

        liveOverlayView.frame = bounds
        liveOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        liveOverlayView.backgroundColor = .clear
        liveOverlayView.isOpaque = false
        liveOverlayView.isHidden = true
        addSubview(liveOverlayView)

        configure(slot: slot, hoboDoc: hoboDoc, hoboAllSlots: hoboAllSlots, isHobo: isHobo, readingMode: readingMode)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if pdfContentLayer.frame != bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pdfContentLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func prepareForReuse() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pdfContentLayer.contents = nil
        CATransaction.commit()
        renderedCGImage = nil
        renderedZoomScale = 0
        isRendered = false
        staticInkView.strokes = []
        staticInkView.hiddenStrokeIDs = []
        staticInkView.textBoxes = []
        staticInkView.hiddenTextBoxID = nil
        staticInkView.isHidden = true
        liveOverlayView.mode = .none
        liveOverlayView.isHidden = true
    }

    func configure(
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

        templateView?.removeFromSuperview()
        templateView = nil
        hoboView?.removeFromSuperview()
        hoboView = nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if bounds.size != slot.size {
            bounds = CGRect(origin: .zero, size: slot.size)
        }
        pdfContentLayer.frame = bounds
        staticInkView.pageSize = slot.size
        staticInkView.smartDarkInk = (!isHobonichiSlot && readingMode == .dark)
        liveOverlayView.smartDarkInk = (!isHobonichiSlot && readingMode == .dark)

        if hoboKind != nil {
            backgroundColor = HobonichiEngine.creamColor
            pdfContentLayer.isHidden = true
            pdfContentLayer.contents = nil
            renderedCGImage = nil
            let hv = HobonichiPaperView(slot: slot, doc: hoboDoc ?? InkDocument.empty(name: ""), allSlots: hoboAllSlots, isHobo: isHobo)
            hv.frame = bounds
            hv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            insertSubview(hv, belowSubview: staticInkView)
            hoboView = hv
            isRendered = true
                renderedZoomScale = 1.0
        } else if slot.effectivePDFPageNumber == nil {
            backgroundColor = Self.paperBackdropColor(for: readingMode)
            pdfContentLayer.isHidden = true
            pdfContentLayer.contents = nil
            renderedCGImage = nil
            let tv = TemplatePaperView(template: slot.template, readingMode: readingMode)
            tv.frame = bounds
            tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            insertSubview(tv, belowSubview: staticInkView)
            templateView = tv
            isRendered = true
                renderedZoomScale = 1.0
        } else {
            backgroundColor = Self.paperBackdropColor(for: readingMode)
            pdfContentLayer.isHidden = false
            pdfContentLayer.contents = nil
            renderedCGImage = nil
            isRendered = false
                renderedZoomScale = 0
        }
        CATransaction.commit()

        staticInkView.strokes = []
        staticInkView.hiddenStrokeIDs = []
        staticInkView.textBoxes = []
        staticInkView.hiddenTextBoxID = nil
        staticInkView.isHidden = true

        liveOverlayView.mode = .none
        liveOverlayView.isHidden = true
    }

    private func syncStaticInkVisibility() {
        let hasContent = !staticInkView.strokes.isEmpty || !staticInkView.textBoxes.isEmpty
        if hasContent {
            if staticInkView.isHidden {
                staticInkView.isHidden = false
                let screenScale = max(1.0, traitCollection.displayScale > 0 ? traitCollection.displayScale : 2.0)
                #if targetEnvironment(macCatalyst)
                let maxVec: CGFloat = 2.0
                #else
                let maxVec: CGFloat = 2.5
                #endif
                let targetScale = min(screenScale * max(1.0, renderedZoomScale > 0 ? renderedZoomScale : 1.0), maxVec)
                if abs(staticInkView.contentScaleFactor - targetScale) > 0.25 {
                    staticInkView.contentScaleFactor = targetScale
                }
            }
            staticInkView.setNeedsDisplay()
        } else {
            staticInkView.isHidden = true
        }
    }

    func setStrokes(_ strokes: [InkStroke], hiddenIDs: Set<String> = []) {
        staticInkView.strokes = strokes
        staticInkView.hiddenStrokeIDs = hiddenIDs
        syncStaticInkVisibility()
    }

    func setTextBoxes(_ boxes: [InkTextBox], hiddenID: String? = nil) {
        staticInkView.textBoxes = boxes
        staticInkView.hiddenTextBoxID = hiddenID
        syncStaticInkVisibility()
    }

    func setHiddenTextBoxID(_ id: String?) {
        staticInkView.hiddenTextBoxID = id
        if !staticInkView.isHidden {
            staticInkView.setNeedsDisplay()
        }
    }

    func setHiddenStrokeIDs(_ ids: Set<String>) {
        staticInkView.hiddenStrokeIDs = ids
        if !staticInkView.isHidden {
            staticInkView.setNeedsDisplay()
        }
    }

    private func showLiveOverlay(for zoomScale: CGFloat? = nil) {
        if liveOverlayView.isHidden {
            liveOverlayView.isHidden = false
            let screenScale = max(1.0, traitCollection.displayScale > 0 ? traitCollection.displayScale : 2.0)
            let z = max(1.0, zoomScale ?? (renderedZoomScale > 0 ? renderedZoomScale : 1.0))
            #if targetEnvironment(macCatalyst)
            let target = min(screenScale * z, 2.0)
            #else
            let target = min(screenScale * z, 2.25)
            #endif
            if abs(liveOverlayView.contentScaleFactor - target) > 0.25 {
                liveOverlayView.contentScaleFactor = target
            }
        }
        liveOverlayView.setNeedsDisplay()
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
        showLiveOverlay()
    }

    func updateEraserRing(center: CGPoint?, radius: CGFloat, zoomScale: CGFloat) {
        if let c = center {
            liveOverlayView.mode = .eraserRing(center: c, radius: radius, zoomScale: zoomScale)
            showLiveOverlay(for: zoomScale)
        } else {
            clearLiveOverlay()
        }
    }

    func updateLaser(points: [LaserPoint], color: UIColor, showTrail: Bool, zoomScale: CGFloat, now: CFTimeInterval) {
        if points.isEmpty {
            clearLiveOverlay()
        } else {
            liveOverlayView.mode = .laser(points: points, color: color, showTrail: showTrail, zoomScale: zoomScale, now: now)
            showLiveOverlay(for: zoomScale)
        }
    }

    func updateLasso(selection: LassoSelection?, zoomScale: CGFloat) {
        guard let sel = selection else {
            clearLiveOverlay()
            return
        }
        if sel.mode == .drawing {
            liveOverlayView.mode = .lassoDrawing(poly: sel.poly, zoomScale: zoomScale)
            showLiveOverlay(for: zoomScale)
        } else if !sel.strokes.isEmpty {
            liveOverlayView.mode = .lassoSelected(selection: sel, zoomScale: zoomScale)
            showLiveOverlay(for: zoomScale)
        } else {
            clearLiveOverlay()
        }
    }

    func clearLiveOverlay() {
        liveOverlayView.mode = .none
        liveOverlayView.isHidden = true
    }

    /// Ultra-fast single-pass direct CALayer contents assignment (< 5 µs, zero UIKit layout invalidation!).
    func applyRenderedCGImage(_ cgImage: CGImage, zoomScale: CGFloat) {
        if !isTemplateOnly {
            renderedCGImage = cgImage
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pdfContentLayer.contents = cgImage
            CATransaction.commit()
        }
        renderedZoomScale = zoomScale
        isRendered = true
        if !staticInkView.isHidden || !liveOverlayView.isHidden || templateView != nil || hoboView != nil {
            refreshVectorScale(for: zoomScale)
        }
    }

    func refreshVectorScale(for zoomScale: CGFloat) {
        let screenScale = max(1.0, traitCollection.displayScale > 0 ? traitCollection.displayScale : 2.0)
        #if targetEnvironment(macCatalyst)
        let maxVecScale: CGFloat = 2.0
        #else
        let maxVecScale: CGFloat = 2.75
        #endif
        let targetScale = min(screenScale * max(1.0, zoomScale), maxVecScale)

        if !staticInkView.isHidden && abs(staticInkView.contentScaleFactor - targetScale) > 0.25 {
            staticInkView.contentScaleFactor = targetScale
            staticInkView.setNeedsDisplay()
        }
        if !liveOverlayView.isHidden {
            let liveTarget = min(screenScale * max(1.0, zoomScale), 2.0)
            if abs(liveOverlayView.contentScaleFactor - liveTarget) > 0.25 {
                liveOverlayView.contentScaleFactor = liveTarget
                liveOverlayView.setNeedsDisplay()
            }
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
            if !staticInkView.isHidden {
                staticInkView.setNeedsDisplay()
            }
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

    /// Dark Paper CoreImage filter operating directly on `CGImage` (only used in Dark Paper mode).
    static func applyDarkPaperFilter(to cgImg: CGImage) -> CGImage {
        let input = CIImage(cgImage: cgImg)
        guard let invert = CIFilter(name: "CIColorInvert") else { return cgImg }
        invert.setValue(input, forKey: kCIInputImageKey)
        guard let inverted = invert.outputImage else { return cgImg }
        let finalCI: CIImage
        if let hue = CIFilter(name: "CIHueAdjust") {
            hue.setValue(inverted, forKey: kCIInputImageKey)
            hue.setValue(Float.pi, forKey: kCIInputAngleKey)
            finalCI = hue.outputImage ?? inverted
        } else {
            finalCI = inverted
        }
        let lifted: CIImage
        if let tone = CIFilter(name: "CIColorControls") {
            tone.setValue(finalCI, forKey: kCIInputImageKey)
            tone.setValue(0.06, forKey: kCIInputBrightnessKey)
            tone.setValue(0.92, forKey: kCIInputContrastKey)
            lifted = tone.outputImage ?? finalCI
        } else {
            lifted = finalCI
        }
        return getCIContext().createCGImage(lifted, from: input.extent) ?? cgImg
    }

    func evictBitmap() {
        guard !isTemplateOnly else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pdfContentLayer.contents = nil
        CATransaction.commit()
        renderedCGImage = nil
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

    static func normalizedPageSize(for cgPage: CGPDFPage) -> CGSize {
        let box = cgPage.getBoxRect(.cropBox)
        let rot = ((Int(cgPage.rotationAngle) % 360) + 360) % 360
        if rot == 90 || rot == 270 {
            return CGSize(width: box.height, height: box.width)
        }
        return box.size
    }

    /// Preview-Class Direct CoreGraphics Renderer:
    /// - Allocates ONE single native-GPU 32-bit `BGRX` bitmap (`byteOrder32Little | noneSkipFirst`)
    /// - Zero `UIGraphicsImageRenderer`, zero `preparingForDisplay()` double copy, zero ICC color conversion
    /// - Explicit `autoreleasepool` frees decoded PDF stream buffers immediately on background thread
    static func renderSlotCGImage(
        slot: PageSlot,
        cgPDFDoc: CGPDFDocument? = nil,
        pdfDoc: PDFDocument? = nil,
        zoomScale: CGFloat,
        maxPixels: CGFloat = 2_400_000,
        readingMode: PDFReadingMode = .original,
        displayScale: CGFloat = 2.0,
        interpolation: CGInterpolationQuality = .none
    ) -> CGImage? {
        autoreleasepool {
            let pageSize = slot.size
            guard pageSize.width > 1, pageSize.height > 1 else { return nil }
            let dpr = max(1.0, min(displayScale, 2.0))
            let maxScale: CGFloat = (interpolation == .none) ? 1.65 : 2.75
            let desiredScale = max(0.35, min(zoomScale * dpr, maxScale))
            let rawPx = (pageSize.width * desiredScale) * (pageSize.height * desiredScale)
            let finalScale = rawPx > maxPixels ? desiredScale * sqrt(maxPixels / rawPx) : desiredScale

            let pxW = max(1, Int((pageSize.width * finalScale).rounded()))
            let pxH = max(1, Int((pageSize.height * finalScale).rounded()))
            // 64-byte row alignment matches Intel HD 630 & Apple GPU cache lines for zero-copy texture upload!
            let bytesPerRow = ((pxW * 4 + 63) / 64) * 64

            guard let ctx = CGContext(
                data: nil,
                width: pxW,
                height: pxH,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: sharedSRGB,
                bitmapInfo: nativeBGRXBitmapInfo
            ) else {
                return nil
            }

            // Configure crisp, energy-efficient Retina PDF rasterization
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSmoothing(false)
            ctx.interpolationQuality = interpolation

            // Flip Y to UIKit top-left coordinates matching `drawSlotBackground`
            ctx.translateBy(x: 0, y: CGFloat(pxH))
            ctx.scaleBy(x: CGFloat(pxW) / pageSize.width, y: -CGFloat(pxH) / pageSize.height)

            drawSlotBackground(slot: slot, cgPDFDoc: cgPDFDoc, pdfDoc: pdfDoc, in: ctx)

            if readingMode == .sepia {
                ctx.saveGState()
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(red: 0.965, green: 0.935, blue: 0.865, alpha: 1.0)
                ctx.fill(CGRect(origin: .zero, size: pageSize))
                ctx.restoreGState()
            }

            guard let cgImg = ctx.makeImage() else { return nil }
            if readingMode == .dark {
                return applyDarkPaperFilter(to: cgImg)
            }
            return cgImg
        }
    }

    /// Convenience `UIImage` wrapper for bookshelf cover thumbnails (`VaultManager`).
    static func renderSlotBackground(
        slot: PageSlot,
        cgPDFDoc: CGPDFDocument? = nil,
        pdfDoc: PDFDocument? = nil,
        zoomScale: CGFloat,
        maxPixels: CGFloat = 2_400_000,
        readingMode: PDFReadingMode = .original,
        displayScale: CGFloat = 2.0,
        fastQuality: Bool = false
    ) -> UIImage {
        if let cg = renderSlotCGImage(
            slot: slot,
            cgPDFDoc: cgPDFDoc,
            pdfDoc: pdfDoc,
            zoomScale: zoomScale,
            maxPixels: maxPixels,
            readingMode: readingMode,
            displayScale: displayScale,
            interpolation: fastQuality ? .none : .low
        ) {
            return UIImage(cgImage: cg)
        }
        return UIImage()
    }

    func updateHobonichiData(doc: InkDocument, allSlots: [PageSlot]) {
        guard let hv = hoboView else { return }
        hv.doc = doc
        hv.allSlots = allSlots
        hv.setNeedsDisplay()
    }

    static func drawSlotBackground(
        slot: PageSlot,
        cgPDFDoc: CGPDFDocument? = nil,
        pdfDoc: PDFDocument? = nil,
        in ctx: CGContext,
        hoboDoc: InkDocument? = nil,
        hoboAllSlots: [PageSlot] = [],
        isHobo: Bool = false
    ) {
        ctx.saveGState()
        if isHobo, HobonichiEngine.slotKind(for: slot, isHobo: true) != nil {
            HobonichiEngine.drawSpread(in: ctx, slot: slot, doc: hoboDoc ?? InkDocument.empty(name: ""), allSlots: hoboAllSlots, isHobo: true)
        } else if let pdfN = slot.effectivePDFPageNumber, let cgPage = cgPDFDoc?.page(at: pdfN) {
            ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            ctx.fill(CGRect(origin: .zero, size: slot.size))
            ctx.translateBy(x: 0, y: slot.size.height)
            ctx.scaleBy(x: 1, y: -1)
            let destRect = CGRect(origin: .zero, size: slot.size)
            let xform = cgPage.getDrawingTransform(.cropBox, rect: destRect, rotate: 0, preserveAspectRatio: true)
            ctx.concatenate(xform)
            ctx.clip(to: cgPage.getBoxRect(.cropBox))
            ctx.drawPDFPage(cgPage)
        } else if let pdfN = slot.effectivePDFPageNumber, let page = pdfDoc?.page(at: pdfN - 1) {
            ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
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
        cgPDFDoc: CGPDFDocument? = nil,
        pdfDoc: PDFDocument? = nil,
        strokes: [InkStroke],
        textBoxes: [InkTextBox] = [],
        scale: CGFloat,
        hoboDoc: InkDocument? = nil,
        hoboAllSlots: [PageSlot] = [],
        isHobo: Bool = false
    ) -> UIImage {
        autoreleasepool {
            let format = UIGraphicsImageRendererFormat()
            format.scale = max(0.25, scale)
            format.opaque = true
            format.preferredRange = .standard
            let renderer = UIGraphicsImageRenderer(size: slot.size, format: format)
            return renderer.image { rendererCtx in
                let ctx = rendererCtx.cgContext
                drawSlotBackground(slot: slot, cgPDFDoc: cgPDFDoc, pdfDoc: pdfDoc, in: ctx, hoboDoc: hoboDoc, hoboAllSlots: hoboAllSlots, isHobo: isHobo)
                drawStrokes(strokes, in: ctx)
                drawTextBoxes(textBoxes, in: ctx)
            }
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
        guard (!strokes.isEmpty || !textBoxes.isEmpty), let ctx = UIGraphicsGetCurrentContext() else { return }
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
            ctx.saveGState()
            ctx.translateBy(x: sel.pivot.x + sel.tx, y: sel.pivot.y + sel.ty)
            if sel.rotation != 0 { ctx.rotate(by: sel.rotation) }
            ctx.scaleBy(x: sel.scale, y: sel.scale)
            ctx.translateBy(x: -sel.pivot.x, y: -sel.pivot.y)
            PageCanvasView.drawStrokes(sel.strokes, in: ctx)
            ctx.restoreGState()

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
