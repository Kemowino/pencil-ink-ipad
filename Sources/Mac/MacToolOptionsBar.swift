import AppKit

/// Pure AppKit circular color swatch button with crisp macOS selection ring.
private final class MacColorSwatchButton: NSButton {
    let hexColor: String
    var isSwatchSelected: Bool = false {
        didSet {
            if isSwatchSelected != oldValue { needsDisplay = true }
        }
    }

    init(hex: String, target: AnyObject?, action: Selector?) {
        self.hexColor = hex
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        self.isBordered = false
        self.title = ""
        self.target = target
        self.action = action
        self.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inner = bounds.insetBy(dx: 4, dy: 4)
        ctx.setFillColor(NSColor.cached(hex: hexColor).cgColor)
        ctx.fillEllipse(in: inner)
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: inner)

        if isSwatchSelected {
            let ring = bounds.insetBy(dx: 1.5, dy: 1.5)
            ctx.setStrokeColor(DesignTokens.nsAccent.cgColor)
            ctx.setLineWidth(2.0)
            ctx.strokeEllipse(in: ring)
        }
    }
}

/// Proportional dot thickness button (Goodnotes/Preview aesthetic).
private final class MacThicknessDotButton: NSButton {
    let dotDiameter: CGFloat
    var isDotSelected: Bool = false {
        didSet { if isDotSelected != oldValue { needsDisplay = true } }
    }

    init(diameter: CGFloat, target: AnyObject?, action: Selector?) {
        self.dotDiameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        self.isBordered = false
        self.title = ""
        self.target = target
        self.action = action
        self.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isDotSelected {
            let bg = bounds.insetBy(dx: 1.5, dy: 1.5)
            ctx.setFillColor(DesignTokens.nsAccent.withAlphaComponent(0.16).cgColor)
            ctx.fillEllipse(in: bg)
            ctx.setStrokeColor(DesignTokens.nsAccent.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1.3)
            ctx.strokeEllipse(in: bg)
        }
        let r = dotDiameter * 0.5
        let dotRect = CGRect(x: bounds.midX - r, y: bounds.midY - r, width: dotDiameter, height: dotDiameter)
        let col = isDotSelected ? DesignTokens.nsAccent : NSColor.labelColor.withAlphaComponent(0.75)
        ctx.setFillColor(col.cgColor)
        ctx.fillEllipse(in: dotRect)
    }
}

/// Slim contextual AppKit accessory bar shown ONLY when Highlighter or Text Box mode is active.
/// Completely hidden (0 px height, 0 CPU) in Read mode!
@MainActor
final class MacToolOptionsBar: NSView {
    var onStyleChanged: (() -> Void)?
    var onDuplicateTextBox: (() -> Void)?
    var onDeleteTextBox: (() -> Void)?
    var onCommitTextBox: (() -> Void)?

    private let bottomDivider = NSBox()
    private let hlStack = NSStackView()
    private let textStack = NSStackView()

    // Highlighter controls
    private var hlSwatchButtons: [MacColorSwatchButton] = []
    private var hlDotButtons: [MacThicknessDotButton] = []
    private let hlStraightBtn = NSButton()
    private let hlHintLabel = NSTextField(labelWithString: "Drag to highlight  ·  Shift = straight  ·  Option-Click = erase")

    // Text Box controls
    private var textSwatchButtons: [MacColorSwatchButton] = []
    private let fontPopup = NSPopUpButton()
    private let sizeMinusBtn = NSButton(title: "−", target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "15 pt")
    private let sizePlusBtn = NSButton(title: "+", target: nil, action: nil)
    private let boldBtn = NSButton(title: "B", target: nil, action: nil)
    private let bgPopup = NSPopUpButton()
    private let activeBoxDivider = NSBox()
    private let dupBoxBtn = NSButton(title: "Duplicate", target: nil, action: nil)
    private let delBoxBtn = NSButton(title: "Delete", target: nil, action: nil)
    private let doneBoxBtn = NSButton(title: "Done", target: nil, action: nil)

    private let bgPresets: [(title: String, hex: String)] = [
        ("No Fill", ""),
        ("Cream", "#fff6d6"),
        ("Sky", "#e6f2ff"),
        ("Rose", "#fdeaf0")
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = DesignTokens.nsChromeSecondary.cgColor
        setupUI()
        syncFromPreferences()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = DesignTokens.nsChromeSecondary.cgColor
    }

    private func makeVDivider() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return b
    }

    private func setupUI() {
        bottomDivider.boxType = .separator
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomDivider)

        // Highlighter Stack
        hlStack.orientation = .horizontal
        hlStack.alignment = .centerY
        hlStack.spacing = 8
        hlStack.translatesAutoresizingMaskIntoConstraints = false

        for (idx, hex) in MacPreferences.shared.hlColors.enumerated() {
            let sw = MacColorSwatchButton(hex: hex, target: self, action: #selector(hlSwatchClicked(_:)))
            sw.tag = idx
            hlSwatchButtons.append(sw)
            hlStack.addArrangedSubview(sw)
        }

        hlStack.addArrangedSubview(makeVDivider())

        let diameters: [CGFloat] = [6.5, 10.5, 14.5]
        for (idx, d) in diameters.enumerated() {
            let btn = MacThicknessDotButton(diameter: d, target: self, action: #selector(hlDotClicked(_:)))
            btn.tag = idx
            hlDotButtons.append(btn)
            hlStack.addArrangedSubview(btn)
        }

        hlStack.addArrangedSubview(makeVDivider())

        hlStraightBtn.title = "Straight"
        hlStraightBtn.image = NSImage(systemSymbolName: "ruler", accessibilityDescription: "Straight")
        hlStraightBtn.imagePosition = .imageLeading
        hlStraightBtn.bezelStyle = .rounded
        hlStraightBtn.setButtonType(.pushOnPushOff)
        hlStraightBtn.controlSize = .small
        hlStraightBtn.target = self
        hlStraightBtn.action = #selector(hlStraightChanged)
        hlStack.addArrangedSubview(hlStraightBtn)

        let hlSpacer = NSView()
        hlSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hlStack.addArrangedSubview(hlSpacer)

        hlHintLabel.font = NSFont.systemFont(ofSize: 11)
        hlHintLabel.textColor = .tertiaryLabelColor
        hlStack.addArrangedSubview(hlHintLabel)
        addSubview(hlStack)

        // Text Box Stack
        textStack.orientation = .horizontal
        textStack.alignment = .centerY
        textStack.spacing = 7
        textStack.translatesAutoresizingMaskIntoConstraints = false

        for (idx, hex) in MacPreferences.shared.textColors.enumerated() {
            let sw = MacColorSwatchButton(hex: hex, target: self, action: #selector(textSwatchClicked(_:)))
            sw.tag = idx
            textSwatchButtons.append(sw)
            textStack.addArrangedSubview(sw)
        }

        textStack.addArrangedSubview(makeVDivider())

        fontPopup.controlSize = .small
        fontPopup.addItems(withTitles: ["Sans", "Serif", "Mono"])
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        textStack.addArrangedSubview(fontPopup)

        sizeMinusBtn.bezelStyle = .rounded
        sizeMinusBtn.controlSize = .small
        sizeMinusBtn.target = self
        sizeMinusBtn.action = #selector(sizeMinus)
        textStack.addArrangedSubview(sizeMinusBtn)

        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        sizeLabel.alignment = .center
        sizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        textStack.addArrangedSubview(sizeLabel)

        sizePlusBtn.bezelStyle = .rounded
        sizePlusBtn.controlSize = .small
        sizePlusBtn.target = self
        sizePlusBtn.action = #selector(sizePlus)
        textStack.addArrangedSubview(sizePlusBtn)

        boldBtn.bezelStyle = .rounded
        boldBtn.setButtonType(.pushOnPushOff)
        boldBtn.controlSize = .small
        boldBtn.font = NSFont.boldSystemFont(ofSize: 11.5)
        boldBtn.target = self
        boldBtn.action = #selector(boldToggled)
        textStack.addArrangedSubview(boldBtn)

        bgPopup.controlSize = .small
        for p in bgPresets { bgPopup.addItem(withTitle: p.title) }
        bgPopup.target = self
        bgPopup.action = #selector(bgChanged)
        textStack.addArrangedSubview(bgPopup)

        let txtSpacer = NSView()
        txtSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.addArrangedSubview(txtSpacer)

        activeBoxDivider.boxType = .separator
        activeBoxDivider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        textStack.addArrangedSubview(activeBoxDivider)

        dupBoxBtn.bezelStyle = .rounded
        dupBoxBtn.controlSize = .small
        dupBoxBtn.target = self
        dupBoxBtn.action = #selector(dupClicked)
        textStack.addArrangedSubview(dupBoxBtn)

        delBoxBtn.bezelStyle = .rounded
        delBoxBtn.controlSize = .small
        delBoxBtn.contentTintColor = .systemRed
        delBoxBtn.target = self
        delBoxBtn.action = #selector(delClicked)
        textStack.addArrangedSubview(delBoxBtn)

        doneBoxBtn.bezelStyle = .rounded
        doneBoxBtn.controlSize = .small
        doneBoxBtn.target = self
        doneBoxBtn.action = #selector(doneClicked)
        textStack.addArrangedSubview(doneBoxBtn)

        addSubview(textStack)

        NSLayoutConstraint.activate([
            bottomDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: bottomAnchor),

            hlStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            hlStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            hlStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setActiveTextBoxControlsVisible(false)
    }

    func update(for mode: MacToolMode, hasActiveTextBox: Bool) {
        hlStack.isHidden = (mode != .highlighter)
        textStack.isHidden = (mode != .textBox && !hasActiveTextBox)
        setActiveTextBoxControlsVisible(hasActiveTextBox)
        syncFromPreferences()
    }

    func setActiveTextBoxControlsVisible(_ visible: Bool) {
        activeBoxDivider.isHidden = !visible
        dupBoxBtn.isHidden = !visible
        delBoxBtn.isHidden = !visible
        doneBoxBtn.isHidden = !visible
    }

    func syncFromPreferences() {
        let p = MacPreferences.shared
        for (i, btn) in hlSwatchButtons.enumerated() {
            btn.isSwatchSelected = (i == p.hlColorIndex)
        }
        for (i, btn) in hlDotButtons.enumerated() {
            btn.isDotSelected = (i == p.hlSizeIndex)
        }
        hlStraightBtn.state = p.hlStraight ? .on : .off

        for (i, btn) in textSwatchButtons.enumerated() {
            btn.isSwatchSelected = (i == p.textColorIndex)
        }
        let fontIdx: Int
        switch p.textFont {
        case "serif": fontIdx = 1
        case "mono": fontIdx = 2
        default: fontIdx = 0
        }
        fontPopup.selectItem(at: fontIdx)
        sizeLabel.stringValue = "\(Int(p.textSize)) pt"
        boldBtn.state = p.textBold ? .on : .off
        let bgIdx = bgPresets.firstIndex(where: { $0.hex.caseInsensitiveCompare(p.textBgHex) == .orderedSame }) ?? 0
        bgPopup.selectItem(at: bgIdx)
    }

    @objc private func hlSwatchClicked(_ sender: MacColorSwatchButton) {
        MacPreferences.shared.hlColorIndex = sender.tag
        syncFromPreferences()
    }

    @objc private func hlDotClicked(_ sender: MacThicknessDotButton) {
        MacPreferences.shared.hlSizeIndex = sender.tag
        syncFromPreferences()
    }

    @objc private func hlStraightChanged() {
        MacPreferences.shared.hlStraight = (hlStraightBtn.state == .on)
    }

    @objc private func textSwatchClicked(_ sender: MacColorSwatchButton) {
        MacPreferences.shared.textColorIndex = sender.tag
        syncFromPreferences()
        onStyleChanged?()
    }

    @objc private func fontChanged() {
        let fonts = ["sans", "serif", "mono"]
        let idx = max(0, min(fonts.count - 1, fontPopup.indexOfSelectedItem))
        MacPreferences.shared.textFont = fonts[idx]
        onStyleChanged?()
    }

    @objc private func sizeMinus() {
        MacPreferences.shared.textSize = max(8, MacPreferences.shared.textSize - 1)
        syncFromPreferences()
        onStyleChanged?()
    }

    @objc private func sizePlus() {
        MacPreferences.shared.textSize = min(72, MacPreferences.shared.textSize + 1)
        syncFromPreferences()
        onStyleChanged?()
    }

    @objc private func boldToggled() {
        MacPreferences.shared.textBold = (boldBtn.state == .on)
        onStyleChanged?()
    }

    @objc private func bgChanged() {
        let idx = max(0, min(bgPresets.count - 1, bgPopup.indexOfSelectedItem))
        MacPreferences.shared.textBgHex = bgPresets[idx].hex
        onStyleChanged?()
    }

    @objc private func dupClicked() { onDuplicateTextBox?() }
    @objc private func delClicked() { onDeleteTextBox?() }
    @objc private func doneClicked() { onCommitTextBox?() }
}
