import AppKit
import QuartzCore

/// Pure AppKit `NSTextView` subclass that cleanly handles `Esc` and `Cmd+Return` to commit.
private final class MacCommitTextView: NSTextView {
    var onCommitShortcut: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Escape (keyCode 53) or Cmd+Return (keyCode 36 / 76 with .command) commits the text box!
        if event.keyCode == 53 {
            onCommitShortcut?()
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command) {
            onCommitShortcut?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Top drag bar for moving an inline text box smoothly across the PDF page.
private final class MacTextBoxDragBar: NSView {
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onDragBegan?(event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        onDragMoved?(event.locationInWindow)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// Right-edge circular resize handle for adjusting text box width cleanly.
private final class MacTextBoxResizeHandle: NSView {
    var onResizeBegan: ((NSPoint) -> Void)?
    var onResizeMoved: ((NSPoint) -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onResizeBegan?(event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        onResizeMoved?(event.locationInWindow)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

/// Pure AppKit inline Text Box editor mounted directly inside `MacPageOverlayView`.
/// Scales cleanly with `PDFView` zoom so live typing matches committed `.ink.json` text 1:1.
final class MacInlineTextBoxView: NSView, NSTextViewDelegate {
    let pageKey: String
    weak var hostOverlay: MacPageOverlayView?
    var box: InkTextBox
    let originalBox: InkTextBox?

    var onChanged: ((InkTextBox) -> Void)?
    var onCommitRequested: (() -> Void)?

    private let dragBar = MacTextBoxDragBar()
    private let gripPill = NSView()
    private let textView = MacCommitTextView()
    private let resizeHandle = MacTextBoxResizeHandle()
    private let borderLayer = CAShapeLayer()

    private let dragBarHeight: CGFloat = 16
    private let handleSize: CGFloat = 14
    private var dragStartWindowPt: NSPoint = .zero
    private var dragStartBoxOrigin: CGPoint = .zero
    private var resizeStartWindowPt: NSPoint = .zero
    private var resizeStartWidth: CGFloat = 220
    private var lastStyleKey: String = ""
    private var lastBorderSize: CGSize = .zero

    private static let noActions: [String: CAAction] = [
        "path": NSNull(),
        "bounds": NSNull(),
        "position": NSNull()
    ]

    override var isFlipped: Bool { true }

    init(pageKey: String, hostOverlay: MacPageOverlayView, box: InkTextBox, originalBox: InkTextBox?) {
        self.pageKey = pageKey
        self.hostOverlay = hostOverlay
        self.box = box
        self.originalBox = originalBox
        super.init(frame: .zero)
        setupUI()
        applyStylingAndLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func currentOverlayScale() -> CGFloat {
        guard let ov = hostOverlay, ov.slot.size.width > 1 else { return 1.0 }
        return max(0.25, ov.bounds.width / ov.slot.size.width)
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.systemBlue.cgColor
        borderLayer.lineWidth = 1.4
        borderLayer.lineDashPattern = [5, 3]
        borderLayer.actions = Self.noActions
        layer?.addSublayer(borderLayer)

        dragBar.wantsLayer = true
        dragBar.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor
        dragBar.layer?.cornerRadius = 4
        dragBar.onDragBegan = { [weak self] winPt in
            guard let self else { return }
            self.dragStartWindowPt = winPt
            self.dragStartBoxOrigin = CGPoint(x: CGFloat(self.box.x), y: CGFloat(self.box.y))
        }
        dragBar.onDragMoved = { [weak self] winPt in
            guard let self, let ov = self.hostOverlay else { return }
            let sc = self.currentOverlayScale()
            let dx = (winPt.x - self.dragStartWindowPt.x) / sc
            // Window Y is bottom-up while flipped page Y is top-down
            let dy = -(winPt.y - self.dragStartWindowPt.y) / sc
            let nx = max(4, min(ov.slot.size.width - CGFloat(self.box.w) - 4, self.dragStartBoxOrigin.x + dx))
            let ny = max(4, min(ov.slot.size.height - 24, self.dragStartBoxOrigin.y + dy))
            self.box.x = (Double(nx) * 100).rounded() / 100
            self.box.y = (Double(ny) * 100).rounded() / 100
            self.box.t = Int64(Date().timeIntervalSince1970 * 1000)
            self.repositionForOverlayBounds()
            self.onChanged?(self.box)
        }
        addSubview(dragBar)

        gripPill.wantsLayer = true
        gripPill.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.75).cgColor
        gripPill.layer?.cornerRadius = 1.5
        dragBar.addSubview(gripPill)

        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.drawsBackground = true
        textView.string = box.text
        textView.onCommitShortcut = { [weak self] in
            self?.onCommitRequested?()
        }
        addSubview(textView)

        resizeHandle.wantsLayer = true
        resizeHandle.layer?.backgroundColor = NSColor.white.cgColor
        resizeHandle.layer?.borderColor = NSColor.systemBlue.cgColor
        resizeHandle.layer?.borderWidth = 2.0
        resizeHandle.layer?.cornerRadius = handleSize * 0.5
        resizeHandle.onResizeBegan = { [weak self] winPt in
            guard let self else { return }
            self.resizeStartWindowPt = winPt
            self.resizeStartWidth = CGFloat(self.box.w)
        }
        resizeHandle.onResizeMoved = { [weak self] winPt in
            guard let self, let ov = self.hostOverlay else { return }
            let sc = self.currentOverlayScale()
            let dx = (winPt.x - self.resizeStartWindowPt.x) / sc
            let maxAvail = max(84, ov.slot.size.width - CGFloat(self.box.x) - 6)
            let nw = max(72, min(maxAvail, self.resizeStartWidth + dx))
            self.box.w = (Double(nw) * 100).rounded() / 100
            self.box.t = Int64(Date().timeIntervalSince1970 * 1000)
            self.repositionForOverlayBounds()
            self.onChanged?(self.box)
        }
        addSubview(resizeHandle)
    }

    func focusEditor() {
        window?.makeFirstResponder(textView)
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
    }

    func applyStylingAndLayout() {
        let sc = currentOverlayScale()
        let scaledSize = max(8, CGFloat(box.fontSize) * sc)
        let styleKey = "\(Int((scaledSize * 10).rounded()))|\(box.fontName ?? "sans")|\(box.bold == true ? 1 : 0)|\(box.color)|\(box.bgColor ?? "")"
        if styleKey != lastStyleKey {
            lastStyleKey = styleKey
            let isBold = (box.bold == true)
            let font: NSFont
            switch box.fontName ?? "sans" {
            case "serif":
                font = NSFont(name: isBold ? "Georgia-Bold" : "Georgia", size: scaledSize)
                    ?? NSFont.systemFont(ofSize: scaledSize, weight: isBold ? .bold : .regular)
            case "mono":
                font = NSFont.monospacedSystemFont(ofSize: scaledSize, weight: isBold ? .bold : .regular)
            default:
                font = NSFont.systemFont(ofSize: scaledSize, weight: isBold ? .bold : .regular)
            }
            textView.font = font
            textView.textColor = NSColor.cached(hex: box.color)
            textView.insertionPointColor = NSColor.systemBlue
            textView.textContainerInset = NSSize(width: 6 * sc, height: 4 * sc)
            if let bgHex = box.bgColor, !bgHex.isEmpty {
                textView.backgroundColor = NSColor.cached(hex: bgHex).withAlphaComponent(0.90)
            } else {
                textView.backgroundColor = NSColor.white.withAlphaComponent(0.92)
            }
        }
        repositionForOverlayBounds()
    }

    func repositionForOverlayBounds() {
        guard let ov = hostOverlay else { return }
        box.text = textView.string
        let measured = box.measuredRect()
        let viewRect = ov.pageRectToViewRect(measured)
        let sc = currentOverlayScale()

        let bodyW = max(72, viewRect.width)
        let bodyH = max(28, viewRect.height)
        let totalW = bodyW + handleSize * 0.5
        let totalH = bodyH + dragBarHeight

        frame = NSRect(
            x: viewRect.minX,
            y: viewRect.minY - dragBarHeight,
            width: totalW,
            height: totalH
        )
        dragBar.frame = NSRect(x: 0, y: 0, width: bodyW, height: dragBarHeight)
        gripPill.frame = NSRect(x: (bodyW - 28) * 0.5, y: (dragBarHeight - 3) * 0.5, width: 28, height: 3)
        textView.frame = NSRect(x: 0, y: dragBarHeight, width: bodyW, height: bodyH)
        textView.textContainer?.containerSize = NSSize(width: max(36, bodyW - 12 * sc), height: 10000)
        resizeHandle.frame = NSRect(
            x: bodyW - handleSize * 0.5,
            y: dragBarHeight + (bodyH - handleSize) * 0.5,
            width: handleSize,
            height: handleSize
        )
        let newBorderSize = CGSize(width: bodyW, height: totalH)
        if newBorderSize != lastBorderSize {
            lastBorderSize = newBorderSize
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            borderLayer.path = CGPath(
                roundedRect: CGRect(origin: .zero, size: newBorderSize),
                cornerWidth: 5,
                cornerHeight: 5,
                transform: nil
            )
            CATransaction.commit()
        }
    }

    func textDidChange(_ notification: Notification) {
        box.text = textView.string
        box.t = Int64(Date().timeIntervalSince1970 * 1000)
        repositionForOverlayBounds()
        onChanged?(box)
    }
}
