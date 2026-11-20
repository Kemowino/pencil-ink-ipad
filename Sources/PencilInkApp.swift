import SwiftUI

@main
struct PencilInkApp: App {
    @StateObject private var vault = VaultManager()
    @StateObject private var syncManager = DriveSyncManager()
    @StateObject private var tabManager = TabManager()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var palette = ToolPaletteStore.shared

    var body: some Scene {
        WindowGroup {
            WorkspaceRootView(syncManagerRef: syncManager)
                .environmentObject(vault)
                .environmentObject(syncManager)
                .environmentObject(tabManager)
                .environmentObject(settings)
                .environmentObject(palette)
                .preferredColorScheme(settings.appTheme.preferredColorScheme)
        }
    }
}
