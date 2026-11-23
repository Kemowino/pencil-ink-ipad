import AppKit
import QuartzCore

/// Dedicated drawing subview for committed strokes & text boxes.
/// Stays `isHidden = true` on unannotated pages so WindowServer allocates **0 bytes** of
/// Retina `CABackingStore` VRAM and skips alpha-blending completely while reading!
private final class MacCommittedInkView: NSView {
    let pageSize: CGSize
    var strokes: [InkStroke] = []
    var textBoxes: [InkTextBox] = []
    var hiddenTextBoxID: String? = nil

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(pageSize: CGSize, frame: NSRect) {
        self.pageSize = pageSize
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.allowsEdgeAntialiasing = false
        layer?.allowsGroupOpacity = false
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !strokes.isEmpty || !textBoxes.isEmpty else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard pageSize.width > 1, pageSize.height > 1, bounds.width > 1, bounds.height > 1 else { return }

        let sx = bounds.width / pageSize.width
        let sy = bounds.height / pageSize.height
        let pageClip = CGRect(
            x: dirtyRect.minX / sx,
            y: dirtyRect.minY / sy,
            width: dirtyRect.width / sx,
            height: dirtyRect.height / sy
        )

        ctx.saveGState()
        ctx.scaleBy(x: sx, y: sy)

        if !strokes.isEmpty {
            MacPageOverlayView.drawStrokes(strokes, in: ctx, clipRect: pageClip)
        }
        if !textBoxes.isEmpty {
            MacPageOverlayView.drawTextBoxes(textBoxes, in: ctx, clipRect: pageClip, hiddenID: hiddenTextBoxID)
        }

        ctx.restoreGState()
    }
}

/// Pure AppKit flipped container `NSView` mounted per visible PDF page by `PDFPageOverlayViewProvider`.
/// - Container does NOT override `draw(_:)` -> **0 bytes** of CoreAnimation backing store on unannotated pages!
/// - Lazily allocates `MacCommittedInkView` and GPU `CAShapeLayer` ONLY on pages that actually have ink/text/live highlight!
/// - `isFlipped = true` maps `(0, 0)` to top-left of the page, matching `.ink.json` 1:1.
final class MacPageOverlayView: NSView {
    let slot: PageSlot

    private var committedView: MacCommittedInkView?
    private var liveShapeLayer: CAShapeLayer?
    weak var activeTextEditor: MacInlineTextBoxView? = nil
    private var lastLayoutSize: CGSize = .zero

    private static let noLayerActions: [String: CAAction] = [
        "path": NSNull(),
        "strokeColor": NSNull(),
        "lineWidth": NSNull(),
        "opacity": NSNull(),
        "hidden": NSNull(),
        "bounds": NSNull(),
        "position": NSNull()
    ]

    private static let wrappingParagraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        return p.copy() as! NSParagraphStyle
    }()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(slot: PageSlot) {
        self.slot = slot
        super.init(frame: NSRect(origin: .zero, size: slot.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.allowsEdgeAntialiasing = false
        layer?.allowsGroupOpacity = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let curSize = bounds.size
        guard curSize != lastLayoutSize else { return }
        lastLayoutSize = curSize

        if let cv = committedView {
            cv.frame = bounds
            if !cv.isHidden {
                cv.needsDisplay = true
            }
        }
        if let lsl = liveShapeLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lsl.frame = bounds
            CATransaction.commit()
        }
        activeTextEditor?.applyStylingAndLayout()
    }

    /// O(1) pass-through hit testing: zero cost unless an inline `MacInlineTextBoxView` is open on this page!
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let editor = activeTextEditor, !editor.isHidden else { return nil }
        let localInSelf = convert(point, from: superview)
        return editor.hitTest(localInSelf)
    }

    // MARK: - Coordinate Conversion (Overlay View <-> `.ink.json` Page Points)

    func viewPointToPagePoint(_ pt: CGPoint) -> CGPoint {
        let bw = max(1.0, bounds.width)
        let bh = max(1.0, bounds.height)
        return CGPoint(
            x: max(0, min(slot.size.width, pt.x * (slot.size.width / bw))),
            y: max(0, min(slot.size.height, pt.y * (slot.size.height / bh)))
        )
    }

    func pageRectToViewRect(_ rect: CGRect) -> CGRect {
        let sx = bounds.width / max(1.0, slot.size.width)
        let sy = bounds.height / max(1.0, slot.size.height)
        return CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
    }

    func viewRectToPageRect(_ rect: CGRect) -> CGRect {
        let sx = slot.size.width / max(1.0, bounds.width)
        let sy = slot.size.height / max(1.0, bounds.height)
        return CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
    }

    // MARK: - Committed Content Updates (Zero Backing Store When Empty + Dirty-Rect Invalidation)

    private func ensureCommittedView() -> MacCommittedInkView {
        if let cv = committedView { return cv }
        let cv = MacCommittedInkView(pageSize: slot.size, frame: bounds)
        if let editor = activeTextEditor {
            addSubview(cv, positioned: .below, relativeTo: editor)
        } else {
            addSubview(cv)
        }
        committedView = cv
        return cv
    }

    func setContent(strokes: [InkStroke], textBoxes: [InkTextBox], hiddenTextBoxID: String? = nil, dirtyPageRect: CGRect? = nil) {
        let nowEmpty = strokes.isEmpty && textBoxes.isEmpty
        if nowEmpty {
            if let cv = committedView {
                cv.strokes = []
                cv.textBoxes = []
                cv.hiddenTextBoxID = nil
                cv.isHidden = true
            }
            return
        }

        let cv = ensureCommittedView()
        let unchanged = !cv.isHidden
            && cv.hiddenTextBoxID == hiddenTextBoxID
            && cv.strokes == strokes
            && cv.textBoxes == textBoxes
        if unchanged { return }

        let wasHidden = cv.isHidden
        cv.strokes = strokes
        cv.textBoxes = textBoxes
        cv.hiddenTextBoxID = hiddenTextBoxID
        if wasHidden {
            cv.frame = bounds
            cv.isHidden = false
            cv.needsDisplay = true
            return
        }
        if let dirty = dirtyPageRect, !dirty.isNull, !dirty.isEmpty {
            let viewDirty = pageRectToViewRect(dirty).intersection(cv.bounds)
            if !viewDirty.isNull && !viewDirty.isEmpty {
                cv.setNeedsDisplay(viewDirty)
                return
            }
        }
        cv.needsDisplay = true
    }

    func appendStroke(_ stroke: InkStroke) {
        let cv = ensureCommittedView()
        let wasHidden = cv.isHidden
        cv.strokes.append(stroke)
        if wasHidden {
            cv.frame = bounds
            cv.isHidden = false
            cv.needsDisplay = true
            return
        }
        let pad = CGFloat(stroke.size) * 2.0 + 8.0
        let dirtyView = pageRectToViewRect(stroke.boundingBox().insetBy(dx: -pad, dy: -pad)).intersection(cv.bounds)
        if !dirtyView.isNull && !dirtyView.isEmpty {
            cv.setNeedsDisplay(dirtyView)
        } else {
            cv.needsDisplay = true
        }
    }

    func setHiddenTextBoxID(_ id: String?) {
        guard let cv = committedView, cv.hiddenTextBoxID != id else { return }
        cv.hiddenTextBoxID = id
        if !cv.isHidden {
            cv.needsDisplay = true
        }
    }

    // MARK: - Lazy GPU Live Highlighter Preview (CAShapeLayer — Zero Bitmap Redraws!)

    private func ensureLiveShapeLayer() -> CAShapeLayer {
        if let existing = liveShapeLayer { return existing }
        let lsl = CAShapeLayer()
        lsl.frame = bounds
        lsl.fillColor = nil
        lsl.lineCap = .round
        lsl.lineJoin = .round
        lsl.isHidden = true
        lsl.actions = Self.noLayerActions
        layer?.addSublayer(lsl)
        liveShapeLayer = lsl
        return lsl
    }

    func updateLiveHighlight(points: [InkPoint], colorHex: String, size: CGFloat, straight: Bool) {
        guard !points.isEmpty else {
            clearLiveHighlight()
            return
        }
        let lsl = ensureLiveShapeLayer()
        let sx = bounds.width / max(1.0, slot.size.width)
        let sy = bounds.height / max(1.0, slot.size.height)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: points[0].x * sx, y: points[0].y * sy))
        if straight || points.count == 2 {
            let last = points[points.count - 1]
            path.addLine(to: CGPoint(x: last.x * sx, y: last.y * sy))
        } else if points.count == 1 {
            path.addLine(to: CGPoint(x: points[0].x * sx + 0.5, y: points[0].y * sy))
        } else {
            for i in 1..<points.count {
                path.addLine(to: CGPoint(x: points[i].x * sx, y: points[i].y * sy))
            }
        }
        let col = NSColor.cached(hex: colorHex)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lsl.frame = bounds
        lsl.isHidden = false
        lsl.strokeColor = col.cgColor
        lsl.lineWidth = size * ((sx + sy) * 0.5)
        lsl.opacity = 0.38
        lsl.path = path
        CATransaction.commit()
    }

    func clearLiveHighlight() {
        guard let lsl = liveShapeLayer, !lsl.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lsl.path = nil
        lsl.isHidden = true
        CATransaction.commit()
    }

    // MARK: - CoreGraphics Vector Rendering (Exact Match to iPadOS & Obsidian)

    nonisolated static func drawStrokes(_ strokes: [InkStroke], in ctx: CGContext, clipRect: CGRect? = nil) {
        guard !strokes.isEmpty else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Pass 1: Highlighters (multiply blend so black PDF text stays razor-sharp underneath!)
        var hasHighlight = false
        for s in strokes where s.tool == "highlighter" {
            hasHighlight = true
            break
        }
        if hasHighlight {
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            ctx.setAlpha(0.42)
            for s in strokes where s.tool == "highlighter" {
                if let rect = clipRect {
                    let pad = CGFloat(s.size) * 1.5 + 4
                    guard s.boundingBox().insetBy(dx: -pad, dy: -pad).intersects(rect) else { continue }
                }
                StrokeGeometry.drawCommittedStroke(s, in: ctx)
            }
            ctx.restoreGState()
        }

        // Pass 2: Pen / Shape strokes drawn on iPad (fountain, brush, ballpoint, smart shapes)
        ctx.setBlendMode(.normal)
        ctx.setAlpha(1.0)
        for s in strokes where s.tool != "highlighter" {
            if let rect = clipRect {
                let pad = CGFloat(s.size) * 1.8 + 4
                guard s.boundingBox().insetBy(dx: -pad, dy: -pad).intersects(rect) else { continue }
            }
            StrokeGeometry.drawCommittedStroke(s, in: ctx)
        }
        ctx.restoreGState()
    }

    nonisolated static func drawTextBoxes(
        _ boxes: [InkTextBox],
        in ctx: CGContext,
        clipRect: CGRect? = nil,
        hiddenID: String? = nil
    ) {
        guard !boxes.isEmpty else { return }
        ctx.saveGState()
        PlatformGraphics.pushFlippedContext(ctx)
        defer {
            PlatformGraphics.popFlippedContext()
            ctx.restoreGState()
        }

        let para = wrappingParagraphStyle
        for box in boxes {
            if box.id == hiddenID { continue }
            let trimmed = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let rect = box.measuredRect()
            if let clip = clipRect, !rect.insetBy(dx: -4, dy: -4).intersects(clip) {
                continue
            }

            if let bgHex = box.bgColor, !bgHex.isEmpty {
                let bgCol = NSColor.cached(hex: bgHex).withAlphaComponent(0.85)
                let path = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
                ctx.setFillColor(bgCol.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            }

            let textColor = NSColor.cached(hex: box.color)
            let font = box.resolvedFont()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: para
            ]
            let drawRect = rect.insetBy(dx: 6, dy: 4)
            (box.text as NSString).draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
        }
    }
}
