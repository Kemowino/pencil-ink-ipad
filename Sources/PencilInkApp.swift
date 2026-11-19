import SwiftUI

@main
struct PencilInkApp: App {
    @StateObject private var vault = VaultManager()
    @StateObject private var syncManager = DriveSyncManager()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(vault)
                .environmentObject(syncManager)
                .preferredColorScheme(.dark)
        }
    }
}
