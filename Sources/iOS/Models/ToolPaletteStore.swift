import Foundation
import SwiftUI

/// Single source of truth for drawing tool colors, thicknesses, and styles across ALL open tabs & files.
/// Any color added (`+`), edited, removed, or thickness customized immediately transfers to every document.
@MainActor
final class ToolPaletteStore: ObservableObject {
    static let shared = ToolPaletteStore()

    // Pen
    @Published var penStyle: PenStyleOption = .fountain { didSet { persist() } }
    @Published var penSmooth: Int = 3 { didSet { persist() } }
    @Published var penColors: [String] = ["#1c1c1e", "#007aff", "#ff3b30", "#30d158"] { didSet { persist() } }
    @Published var penColorIndex: Int = 0 { didSet { persist() } }
    @Published var penSizes: [Double] = [1.4, 2.6, 4.8] { didSet { persist() } }
    @Published var penSizeIndex: Int = 1 { didSet { persist() } }
    @Published var holdToShape: Bool = true { didSet { persist() } }

    // Highlighter
    @Published var hlColors: [String] = ["#ffde59", "#69e6a6", "#ff94af"] { didSet { persist() } }
    @Published var hlColorIndex: Int = 0 { didSet { persist() } }
    @Published var hlSizes: [Double] = [12.0, 18.0, 28.0] { didSet { persist() } }
    @Published var hlSizeIndex: Int = 1 { didSet { persist() } }
    @Published var hlStraight: Bool = false { didSet { persist() } }

    // Eraser
    @Published var eraserMode: EraserModeOption = .stroke { didSet { persist() } }
    @Published var eraserSizes: [Double] = [10.0, 22.0, 40.0] { didSet { persist() } }
    @Published var eraserSizeIndex: Int = 1 { didSet { persist() } }
    @Published var eraseHlOnly: Bool = false { didSet { persist() } }

    // Text Box
    @Published var textColors: [String] = ["#1c1c1e", "#007aff", "#ff3b30", "#2f855a"] { didSet { persist() } }
    @Published var textColorIndex: Int = 0 { didSet { persist() } }
    @Published var textSize: Double = 16.0 { didSet { persist() } }
    @Published var textFont: TextFontOption = .sans { didSet { persist() } }
    @Published var textBold: Bool = false { didSet { persist() } }
    @Published var textBgHex: String = "" { didSet { persist() } }

    // Laser
    @Published var laserColors: [String] = ["#ff3b30", "#0a84ff", "#30d158", "#ff9f0a"] { didSet { persist() } }
    @Published var laserColorIndex: Int = 0 { didSet { persist() } }
    @Published var laserTrail: Bool = true { didSet { persist() } }

    let textBgPresets: [(name: String, hex: String)] = [
        ("None", ""),
        ("Cream", "#fff6d6"),
        ("Sky", "#e6f2ff"),
        ("Rose", "#fdeaf0")
    ]

    let quickInkPresets: [String] = [
        "#1c1c1e", "#3a3a3c", "#007aff", "#5856d6",
        "#ff3b30", "#ff9500", "#30d158", "#00c7be",
        "#af52de", "#ff2d55", "#a2845e", "#ffffff"
    ]

    let quickHighlighterPresets: [String] = [
        "#ffde59", "#69e6a6", "#ff94af", "#74c7ff",
        "#d0a8ff", "#ffb36b", "#9ef0f0", "#f4a8d4",
        "#c5e86c", "#ffe08a", "#a9c1ff", "#d4d4d8"
    ]

    private let prefsKey = "pencilink.native.prefs.v2"
    private var loading = false

    var activePenColorHex: String {
        guard !penColors.isEmpty else { return "#1c1c1e" }
        return penColors[max(0, min(penColors.count - 1, penColorIndex))]
    }
    var activePenSize: Double {
        penSizes[max(0, min(penSizes.count - 1, penSizeIndex))]
    }
    var activeHlColorHex: String {
        guard !hlColors.isEmpty else { return "#ffde59" }
        return hlColors[max(0, min(hlColors.count - 1, hlColorIndex))]
    }
    var activeHlSize: Double {
        hlSizes[max(0, min(hlSizes.count - 1, hlSizeIndex))]
    }
    var activeEraserRadius: Double {
        eraserSizes[max(0, min(eraserSizes.count - 1, eraserSizeIndex))] * 0.5
    }
    var activeTextColorHex: String {
        guard !textColors.isEmpty else { return "#1c1c1e" }
        return textColors[max(0, min(textColors.count - 1, textColorIndex))]
    }
    var activeLaserColorHex: String {
        guard !laserColors.isEmpty else { return "#ff3b30" }
        return laserColors[max(0, min(laserColors.count - 1, laserColorIndex))]
    }

    // Dynamic Palette Operations
    func addPenColor(_ hex: String) {
        penColors.append(hex)
        penColorIndex = penColors.count - 1
    }
    func removePenColor(at idx: Int) {
        guard penColors.count > 1, penColors.indices.contains(idx) else { return }
        penColors.remove(at: idx)
        penColorIndex = max(0, min(penColors.count - 1, penColorIndex))
    }

    func addHlColor(_ hex: String) {
        hlColors.append(hex)
        hlColorIndex = hlColors.count - 1
    }
    func removeHlColor(at idx: Int) {
        guard hlColors.count > 1, hlColors.indices.contains(idx) else { return }
        hlColors.remove(at: idx)
        hlColorIndex = max(0, min(hlColors.count - 1, hlColorIndex))
    }

    func addTextColor(_ hex: String) {
        textColors.append(hex)
        textColorIndex = textColors.count - 1
    }
    func removeTextColor(at idx: Int) {
        guard textColors.count > 1, textColors.indices.contains(idx) else { return }
        textColors.remove(at: idx)
        textColorIndex = max(0, min(textColors.count - 1, textColorIndex))
    }

    func addLaserColor(_ hex: String) {
        laserColors.append(hex)
        laserColorIndex = laserColors.count - 1
    }
    func removeLaserColor(at idx: Int) {
        guard laserColors.count > 1, laserColors.indices.contains(idx) else { return }
        laserColors.remove(at: idx)
        laserColorIndex = max(0, min(laserColors.count - 1, laserColorIndex))
    }

    private struct SavedPrefs: Codable {
        var penStyle: String?
        var penSmooth: Int?
        var penColors: [String]?
        var penColorIndex: Int?
        var penSizes: [Double]?
        var penSizeIndex: Int?
        var holdToShape: Bool?
        var hlColors: [String]?
        var hlColorIndex: Int?
        var hlSizes: [Double]?
        var hlSizeIndex: Int?
        var hlStraight: Bool?
        var eraserMode: String?
        var eraserSizes: [Double]?
        var eraserSizeIndex: Int?
        var eraseHlOnly: Bool?
        var laserColors: [String]?
        var laserColorIndex: Int?
        var laserColorHex: String?
        var laserTrail: Bool?
        var textColors: [String]?
        var textColorIndex: Int?
        var textSize: Double?
        var textFont: String?
        var textBold: Bool?
        var textBgHex: String?
    }

    private init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: prefsKey),
              let p = try? JSONDecoder().decode(SavedPrefs.self, from: data) else { return }
        loading = true
        defer { loading = false }
        if let v = p.penStyle, let parsed = PenStyleOption(rawValue: v) { penStyle = parsed }
        if let v = p.penSmooth { penSmooth = max(0, min(5, v)) }
        if let c = p.penColors, !c.isEmpty { penColors = c }
        if let i = p.penColorIndex { penColorIndex = max(0, min(penColors.count - 1, i)) }
        if let s = p.penSizes, s.count == 3 { penSizes = s }
        if let i = p.penSizeIndex { penSizeIndex = max(0, min(2, i)) }
        if let v = p.holdToShape { holdToShape = v }

        if let c = p.hlColors, !c.isEmpty { hlColors = c }
        if let i = p.hlColorIndex { hlColorIndex = max(0, min(hlColors.count - 1, i)) }
        if let s = p.hlSizes, s.count == 3 { hlSizes = s }
        if let i = p.hlSizeIndex { hlSizeIndex = max(0, min(2, i)) }
        if let v = p.hlStraight { hlStraight = v }

        if let v = p.eraserMode, let parsed = EraserModeOption(rawValue: v) { eraserMode = parsed }
        if let s = p.eraserSizes, s.count == 3 { eraserSizes = s }
        if let i = p.eraserSizeIndex { eraserSizeIndex = max(0, min(2, i)) }
        if let v = p.eraseHlOnly { eraseHlOnly = v }

        if let c = p.laserColors, !c.isEmpty { laserColors = c }
        if let i = p.laserColorIndex {
            laserColorIndex = max(0, min(laserColors.count - 1, i))
        } else if let hex = p.laserColorHex, let idx = laserColors.firstIndex(where: { $0.caseInsensitiveCompare(hex) == .orderedSame }) {
            laserColorIndex = idx
        }
        if let v = p.laserTrail { laserTrail = v }

        if let c = p.textColors, !c.isEmpty { textColors = c }
        if let i = p.textColorIndex { textColorIndex = max(0, min(textColors.count - 1, i)) }
        if let v = p.textSize { textSize = max(8, min(72, v)) }
        if let v = p.textFont, let parsed = TextFontOption(rawValue: v) { textFont = parsed }
        if let v = p.textBold { textBold = v }
        if let v = p.textBgHex { textBgHex = v }
    }

    private var persistWorkItem: DispatchWorkItem?

    private func persist() {
        guard !loading else { return }
        persistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.writePrefsNow()
        }
        persistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func writePrefsNow() {
        let p = SavedPrefs(
            penStyle: penStyle.rawValue,
            penSmooth: penSmooth,
            penColors: penColors,
            penColorIndex: penColorIndex,
            penSizes: penSizes,
            penSizeIndex: penSizeIndex,
            holdToShape: holdToShape,
            hlColors: hlColors,
            hlColorIndex: hlColorIndex,
            hlSizes: hlSizes,
            hlSizeIndex: hlSizeIndex,
            hlStraight: hlStraight,
            eraserMode: eraserMode.rawValue,
            eraserSizes: eraserSizes,
            eraserSizeIndex: eraserSizeIndex,
            eraseHlOnly: eraseHlOnly,
            laserColors: laserColors,
            laserColorIndex: laserColorIndex,
            laserColorHex: activeLaserColorHex,
            laserTrail: laserTrail,
            textColors: textColors,
            textColorIndex: textColorIndex,
            textSize: textSize,
            textFont: textFont.rawValue,
            textBold: textBold,
            textBgHex: textBgHex
        )
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: prefsKey)
        }
    }
}
