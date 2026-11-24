import Foundation
import AppKit

enum MacSyncMode: String, CaseIterable {
    case smart = "smart"
    case manual = "manual"

    var title: String {
        switch self {
        case .smart: return "Smart (Idle & Window Return)"
        case .manual: return "Manual Only"
        }
    }
}

enum MacToolMode: Int, CaseIterable {
    case read = 0
    case highlighter = 1
    case textBox = 2

    var title: String {
        switch self {
        case .read: return "Read"
        case .highlighter: return "Highlight"
        case .textBox: return "Text Box"
        }
    }
}

enum MacPaperMode: String, CaseIterable {
    case original = "original"
    case sepia = "sepia"
    case dark = "dark"

    var title: String {
        switch self {
        case .original: return "Original Paper"
        case .sepia: return "Warm Sepia"
        case .dark: return "Dark Paper"
        }
    }

    var symbolName: String {
        switch self {
        case .original: return "sun.max"
        case .sepia: return "book.fill"
        case .dark: return "moon.fill"
        }
    }

    var paperColor: NSColor {
        switch self {
        case .original: return .white
        case .sepia: return NSColor(red: 0.965, green: 0.935, blue: 0.870, alpha: 1.0)
        case .dark: return NSColor(red: 0.110, green: 0.115, blue: 0.130, alpha: 1.0)
        }
    }
}

enum MacLibraryDisplayMode: String {
    case grid = "grid"
    case list = "list"
}

enum MacLibrarySortMode: String, CaseIterable {
    case date = "date"
    case name = "name"
    case annotated = "annotated"

    var title: String {
        switch self {
        case .date: return "Date Modified"
        case .name: return "Name"
        case .annotated: return "Annotated First"
        }
    }
}

extension Notification.Name {
    static let macToolPrefsDidChange = Notification.Name("pencilink.mac.toolPrefsDidChange")
    static let macRenderQualityDidChange = Notification.Name("pencilink.mac.renderQualityDidChange")
    static let macPaperModeDidChange = Notification.Name("pencilink.mac.paperModeDidChange")
}

/// Ultra-lean UserDefaults preferences for Intel macOS (zero SwiftUI / Combine overhead on scroll!).
@MainActor
final class MacPreferences {
    static let shared = MacPreferences()

    private let key = "pencilink.mac.prefs.v1"
    private var loading = false
    private var persistTimer: DispatchSourceTimer?

    var syncMode: MacSyncMode = .smart {
        didSet { if syncMode != oldValue { schedulePersist() } }
    }

    /// `false` = fast bilinear embedded image resampling (vector PDF text stays 100% crisp CoreText, much cooler CPU).
    var highQualityImages: Bool = false {
        didSet {
            if highQualityImages != oldValue {
                schedulePersist()
                NotificationCenter.default.post(name: .macRenderQualityDidChange, object: nil)
            }
        }
    }

    var paperMode: MacPaperMode = .original {
        didSet {
            if paperMode != oldValue {
                schedulePersist()
                NotificationCenter.default.post(name: .macPaperModeDidChange, object: nil)
            }
        }
    }

    var libraryDisplayMode: MacLibraryDisplayMode = .grid {
        didSet { if libraryDisplayMode != oldValue { schedulePersist() } }
    }

    var librarySortMode: MacLibrarySortMode = .date {
        didSet { if librarySortMode != oldValue { schedulePersist() } }
    }

    // Highlighter defaults (exact same palette harmony as iPadOS)
    var hlColors: [String] = ["#ffde59", "#69e6a6", "#ff94af", "#74c7ff", "#d0a8ff"] {
        didSet { schedulePersist(); notifyTools() }
    }
    var hlColorIndex: Int = 0 {
        didSet { schedulePersist(); notifyTools() }
    }
    var hlSizes: [Double] = [12.0, 18.0, 26.0] {
        didSet { schedulePersist(); notifyTools() }
    }
    var hlSizeIndex: Int = 1 {
        didSet { schedulePersist(); notifyTools() }
    }
    var hlStraight: Bool = true {
        didSet { schedulePersist(); notifyTools() }
    }

    // Text Box defaults
    var textColors: [String] = ["#1c1c1e", "#007aff", "#ff3b30", "#2f855a", "#af52de"] {
        didSet { schedulePersist(); notifyTools() }
    }
    var textColorIndex: Int = 0 {
        didSet { schedulePersist(); notifyTools() }
    }
    var textSize: Double = 15.0 {
        didSet { schedulePersist(); notifyTools() }
    }
    var textFont: String = "sans" { // "sans" | "serif" | "mono"
        didSet { schedulePersist(); notifyTools() }
    }
    var textBold: Bool = false {
        didSet { schedulePersist(); notifyTools() }
    }
    var textBgHex: String = "" {
        didSet { schedulePersist(); notifyTools() }
    }

    var activeHlColorHex: String {
        guard !hlColors.isEmpty else { return "#ffde59" }
        return hlColors[max(0, min(hlColors.count - 1, hlColorIndex))]
    }

    var activeHlSize: Double {
        guard !hlSizes.isEmpty else { return 18.0 }
        return hlSizes[max(0, min(hlSizes.count - 1, hlSizeIndex))]
    }

    var activeTextColorHex: String {
        guard !textColors.isEmpty else { return "#1c1c1e" }
        return textColors[max(0, min(textColors.count - 1, textColorIndex))]
    }

    private struct Snapshot: Codable {
        var syncMode: String?
        var highQualityImages: Bool?
        var paperMode: String?
        var libraryDisplayMode: String?
        var librarySortMode: String?
        var hlColors: [String]?
        var hlColorIndex: Int?
        var hlSizes: [Double]?
        var hlSizeIndex: Int?
        var hlStraight: Bool?
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

    private func notifyTools() {
        guard !loading else { return }
        NotificationCenter.default.post(name: .macToolPrefsDidChange, object: nil)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        loading = true
        defer { loading = false }
        if let v = s.syncMode, let m = MacSyncMode(rawValue: v) { syncMode = m }
        if let hq = s.highQualityImages { highQualityImages = hq }
        if let pm = s.paperMode, let parsed = MacPaperMode(rawValue: pm) { paperMode = parsed }
        if let dm = s.libraryDisplayMode, let parsed = MacLibraryDisplayMode(rawValue: dm) { libraryDisplayMode = parsed }
        if let sm = s.librarySortMode, let parsed = MacLibrarySortMode(rawValue: sm) { librarySortMode = parsed }
        if let c = s.hlColors, !c.isEmpty { hlColors = c }
        if let i = s.hlColorIndex { hlColorIndex = max(0, min(hlColors.count - 1, i)) }
        if let sz = s.hlSizes, sz.count == 3 { hlSizes = sz }
        if let i = s.hlSizeIndex { hlSizeIndex = max(0, min(2, i)) }
        if let b = s.hlStraight { hlStraight = b }
        if let c = s.textColors, !c.isEmpty { textColors = c }
        if let i = s.textColorIndex { textColorIndex = max(0, min(textColors.count - 1, i)) }
        if let sz = s.textSize { textSize = max(8, min(72, sz)) }
        if let f = s.textFont, ["sans", "serif", "mono"].contains(f) { textFont = f }
        if let b = s.textBold { textBold = b }
        if let bg = s.textBgHex { textBgHex = bg }
    }

    private func schedulePersist() {
        guard !loading else { return }
        persistTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(250), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            self?.persistTimer?.cancel()
            self?.persistTimer = nil
            self?.writeNow()
        }
        persistTimer = t
        t.resume()
    }

    private func writeNow() {
        let snap = Snapshot(
            syncMode: syncMode.rawValue,
            highQualityImages: highQualityImages,
            paperMode: paperMode.rawValue,
            libraryDisplayMode: libraryDisplayMode.rawValue,
            librarySortMode: librarySortMode.rawValue,
            hlColors: hlColors,
            hlColorIndex: hlColorIndex,
            hlSizes: hlSizes,
            hlSizeIndex: hlSizeIndex,
            hlStraight: hlStraight,
            textColors: textColors,
            textColorIndex: textColorIndex,
            textSize: textSize,
            textFont: textFont,
            textBold: textBold,
            textBgHex: textBgHex
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
