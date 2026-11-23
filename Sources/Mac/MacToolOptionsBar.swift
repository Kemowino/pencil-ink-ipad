import AppKit

/// Pure AppKit circular color swatch button (zero SwiftUI, crisp native highlight ring).
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
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.20).cgColor)
        ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: inner)

        if isSwatchSelected {
            let ring = bounds.insetBy(dx: 1.5, dy: 1.5)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2.0)
            ctx.strokeEllipse(in: ring)
        }
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

    private let divider = NSBox()
    private let hlStack = NSStackView()
    private let textStack = NSStackView()

    // Highlighter controls
    private var hlSwatchButtons: [MacColorSwatchButton] = []
    private let hlSizeSegment = NSSegmentedControl(labels: ["Fine", "Med", "Thick"], trackingMode: .selectOne, target: nil, action: nil)
    private let hlStraightCheck = NSButton(checkboxWithTitle: "Straight Line", target: nil, action: nil)
    private let hlHintLabel = NSTextField(labelWithString: "Drag to highlight · Shift = straight · Option-Click = erase")

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
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setupUI()
        syncFromPreferences()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    private func setupUI() {
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        // Highlighter Stack
        hlStack.orientation = .horizontal
        hlStack.alignment = .centerY
        hlStack.spacing = 8
        hlStack.translatesAutoresizingMaskIntoConstraints = false

        let hlLbl = NSTextField(labelWithString: "Highlighter:")
        hlLbl.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        hlLbl.textColor = .secondaryLabelColor
        hlStack.addArrangedSubview(hlLbl)

        for (idx, hex) in MacPreferences.shared.hlColors.enumerated() {
            let sw = MacColorSwatchButton(hex: hex, target: self, action: #selector(hlSwatchClicked(_:)))
            sw.tag = idx
            hlSwatchButtons.append(sw)
            hlStack.addArrangedSubview(sw)
        }

        hlSizeSegment.controlSize = .small
        hlSizeSegment.target = self
        hlSizeSegment.action = #selector(hlSizeChanged)
        hlStack.addArrangedSubview(hlSizeSegment)

        hlStraightCheck.controlSize = .small
        hlStraightCheck.target = self
        hlStraightCheck.action = #selector(hlStraightChanged)
        hlStack.addArrangedSubview(hlStraightCheck)

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

        let txtLbl = NSTextField(labelWithString: "Text:")
        txtLbl.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        txtLbl.textColor = .secondaryLabelColor
        textStack.addArrangedSubview(txtLbl)

        for (idx, hex) in MacPreferences.shared.textColors.enumerated() {
            let sw = MacColorSwatchButton(hex: hex, target: self, action: #selector(textSwatchClicked(_:)))
            sw.tag = idx
            textSwatchButtons.append(sw)
            textStack.addArrangedSubview(sw)
        }

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
        doneBoxBtn.keyEquivalent = ""
        doneBoxBtn.target = self
        doneBoxBtn.action = #selector(doneClicked)
        textStack.addArrangedSubview(doneBoxBtn)

        addSubview(textStack)

        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),

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
        hlSizeSegment.selectedSegment = max(0, min(2, p.hlSizeIndex))
        hlStraightCheck.state = p.hlStraight ? .on : .off

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

    @objc private func hlSizeChanged() {
        MacPreferences.shared.hlSizeIndex = hlSizeSegment.selectedSegment
    }

    @objc private func hlStraightChanged() {
        MacPreferences.shared.hlStraight = (hlStraightCheck.state == .on)
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
