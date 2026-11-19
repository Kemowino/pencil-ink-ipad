import SwiftUI

@main
struct PencilInkApp: App {
    @StateObject private var vault = VaultManager()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(vault)
                .preferredColorScheme(.dark)
        }
    }
}
