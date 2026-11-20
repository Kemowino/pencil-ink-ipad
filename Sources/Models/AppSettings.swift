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

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var appTheme: AppThemeOption = .dark { didSet { persist() } }
    @Published var pdfReadingMode: PDFReadingMode = .original { didSet { persist() } }
    @Published var showTabBar: Bool = true { didSet { persist() } }
    @Published var restoreTabsOnLaunch: Bool = true { didSet { persist() } }
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
    @Published var syncPollSeconds: Double = 3.5 { didSet { persist() } }
    @Published var compactToolbar: Bool = false { didSet { persist() } }

    private let storageKey = "pencilink.native.appsettings.v1"
    private var loading = false

    private struct Snapshot: Codable {
        var appTheme: AppThemeOption
        var pdfReadingMode: PDFReadingMode
        var showTabBar: Bool
        var restoreTabsOnLaunch: Bool
        var drawWithFinger: Bool
        var pencilDoubleTap: PencilDoubleTapAction
        var fingerTapUndoRedo: Bool
        var hapticsEnabled: Bool
        var keepScreenAwake: Bool
        var syncPollSeconds: Double
        var compactToolbar: Bool
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
        appTheme = s.appTheme
        pdfReadingMode = s.pdfReadingMode
        showTabBar = s.showTabBar
        restoreTabsOnLaunch = s.restoreTabsOnLaunch
        drawWithFinger = s.drawWithFinger
        pencilDoubleTap = s.pencilDoubleTap
        fingerTapUndoRedo = s.fingerTapUndoRedo
        hapticsEnabled = s.hapticsEnabled
        keepScreenAwake = s.keepScreenAwake
        syncPollSeconds = s.syncPollSeconds
        compactToolbar = s.compactToolbar
    }

    private func persist() {
        guard !loading else { return }
        let snap = Snapshot(
            appTheme: appTheme,
            pdfReadingMode: pdfReadingMode,
            showTabBar: showTabBar,
            restoreTabsOnLaunch: restoreTabsOnLaunch,
            drawWithFinger: drawWithFinger,
            pencilDoubleTap: pencilDoubleTap,
            fingerTapUndoRedo: fingerTapUndoRedo,
            hapticsEnabled: hapticsEnabled,
            keepScreenAwake: keepScreenAwake,
            syncPollSeconds: syncPollSeconds,
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
