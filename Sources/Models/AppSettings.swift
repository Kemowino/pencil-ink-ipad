import Foundation
import SwiftUI
import UIKit

enum AppThemeOption: String, CaseIterable, Identifiable, Codable {
    case dark = "dark"
    case light = "light"
    case system = "system"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "System"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

enum PDFReadingMode: String, CaseIterable, Identifiable, Codable {
    case original = "original"
    case dark = "dark"
    case sepia = "sepia"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Original"
        case .dark: return "Dark Paper"
        case .sepia: return "Warm Sepia"
        }
    }

    var systemImage: String {
        switch self {
        case .original: return "sun.max"
        case .dark: return "moon.fill"
        case .sepia: return "book.fill"
        }
    }
}

enum PencilDoubleTapAction: String, CaseIterable, Identifiable, Codable {
    case switchEraser = "eraser"
    case switchLastTool = "last"
    case off = "off"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .switchEraser: return "Switch Pen / Eraser"
        case .switchLastTool: return "Switch to Previous Tool"
        case .off: return "Off"
        }
    }
}

enum ToolbarPosition: String, CaseIterable, Identifiable, Codable {
    case top = "top"
    case left = "left"
    case right = "right"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .top: return "Top (Goodnotes)"
        case .left: return "Left Side (Noteshelf)"
        case .right: return "Right Side"
        }
    }

    var isVertical: Bool {
        self == .left || self == .right
    }
}

enum SyncBehaviorMode: String, CaseIterable, Identifiable, Codable {
    case smart = "smart"
    case manual = "manual"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: return "Smart (On Idle & Return)"
        case .manual: return "Manual Only"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var appTheme: AppThemeOption = .dark { didSet { persist() } }
    @Published var pdfReadingMode: PDFReadingMode = .original { didSet { persist() } }
    @Published var showTabBar: Bool = true { didSet { persist() } }
    @Published var restoreTabsOnLaunch: Bool = true { didSet { persist() } }
    @Published var startInHandMode: Bool = false { didSet { persist() } }
    @Published var toolbarPosition: ToolbarPosition = .top { didSet { persist() } }
    @Published var hiddenTools: Set<String> = [] { didSet { persist() } }
    @Published var drawWithFinger: Bool = false { didSet { persist() } }
    @Published var pencilDoubleTap: PencilDoubleTapAction = .switchEraser { didSet { persist() } }
    @Published var fingerTapUndoRedo: Bool = true { didSet { persist() } }
    @Published var hapticsEnabled: Bool = true { didSet { persist() } }
    @Published var keepScreenAwake: Bool = false {
        didSet {
            #if !targetEnvironment(macCatalyst)
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
            #endif
            persist()
        }
    }
    @Published var syncMode: SyncBehaviorMode = .smart { didSet { persist() } }
    @Published var compactToolbar: Bool = false { didSet { persist() } }

    private let storageKey = "pencilink.native.appsettings.v1"
    private var loading = false

    func isToolVisible(_ tool: DrawingTool) -> Bool {
        !hiddenTools.contains(tool.rawValue)
    }

    func setToolVisible(_ tool: DrawingTool, visible: Bool) {
        if visible {
            hiddenTools.remove(tool.rawValue)
        } else {
            // Always keep at least one tool visible in the toolbar
            let currentlyVisible = DrawingTool.allCases.filter { !hiddenTools.contains($0.rawValue) }
            guard currentlyVisible.count > 1 else { return }
            hiddenTools.insert(tool.rawValue)
        }
    }

    func resetToolbarDefaults() {
        toolbarPosition = .top
        hiddenTools = []
        compactToolbar = false
    }

    private struct Snapshot: Codable {
        var appTheme: AppThemeOption?
        var pdfReadingMode: PDFReadingMode?
        var showTabBar: Bool?
        var restoreTabsOnLaunch: Bool?
        var startInHandMode: Bool?
        var toolbarPosition: ToolbarPosition?
        var hiddenTools: [String]?
        var drawWithFinger: Bool?
        var pencilDoubleTap: PencilDoubleTapAction?
        var fingerTapUndoRedo: Bool?
        var hapticsEnabled: Bool?
        var keepScreenAwake: Bool?
        var syncMode: SyncBehaviorMode?
        var syncPollSeconds: Double?
        var compactToolbar: Bool?
    }

    private init() {
        load()
        #if !targetEnvironment(macCatalyst)
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
        #endif
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        loading = true
        defer { loading = false }
        if let v = s.appTheme { appTheme = v }
        if let v = s.pdfReadingMode { pdfReadingMode = v }
        if let v = s.showTabBar { showTabBar = v }
        if let v = s.restoreTabsOnLaunch { restoreTabsOnLaunch = v }
        if let v = s.startInHandMode { startInHandMode = v }
        if let v = s.toolbarPosition { toolbarPosition = v }
        if let v = s.hiddenTools { hiddenTools = Set(v) }
        if let v = s.drawWithFinger { drawWithFinger = v }
        if let v = s.pencilDoubleTap { pencilDoubleTap = v }
        if let v = s.fingerTapUndoRedo { fingerTapUndoRedo = v }
        if let v = s.hapticsEnabled { hapticsEnabled = v }
        if let v = s.keepScreenAwake { keepScreenAwake = v }
        if let v = s.syncMode {
            syncMode = v
        } else if let legacyPoll = s.syncPollSeconds, legacyPoll == 0 {
            syncMode = .manual
        }
        if let v = s.compactToolbar { compactToolbar = v }
    }

    private func persist() {
        guard !loading else { return }
        let snap = Snapshot(
            appTheme: appTheme,
            pdfReadingMode: pdfReadingMode,
            showTabBar: showTabBar,
            restoreTabsOnLaunch: restoreTabsOnLaunch,
            startInHandMode: startInHandMode,
            toolbarPosition: toolbarPosition,
            hiddenTools: Array(hiddenTools),
            drawWithFinger: drawWithFinger,
            pencilDoubleTap: pencilDoubleTap,
            fingerTapUndoRedo: fingerTapUndoRedo,
            hapticsEnabled: hapticsEnabled,
            keepScreenAwake: keepScreenAwake,
            syncMode: syncMode,
            syncPollSeconds: nil,
            compactToolbar: compactToolbar
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

enum Haptics {
    @MainActor
    static func light() {
        #if !targetEnvironment(macCatalyst)
        guard AppSettings.shared.hapticsEnabled else { return }
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred()
        #endif
    }

    @MainActor
    static func selection() {
        #if !targetEnvironment(macCatalyst)
        guard AppSettings.shared.hapticsEnabled else { return }
        let g = UISelectionFeedbackGenerator()
        g.selectionChanged()
        #endif
    }

    @MainActor
    static func success() {
        #if !targetEnvironment(macCatalyst)
        guard AppSettings.shared.hapticsEnabled else { return }
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.success)
        #endif
    }
}
