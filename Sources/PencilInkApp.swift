import SwiftUI

@main
struct PencilInkApp: App {
    @StateObject private var vault = VaultManager()
    @StateObject private var syncManager = DriveSyncManager()
    @StateObject private var tabManager = TabManager()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            WorkspaceRootView()
                .environmentObject(vault)
                .environmentObject(syncManager)
                .environmentObject(tabManager)
                .environmentObject(settings)
                .preferredColorScheme(settings.appTheme.preferredColorScheme)
        }
    }
}
