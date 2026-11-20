import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var vault: VaultManager
    @EnvironmentObject var syncManager: DriveSyncManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var onChooseVaultFolder: (() -> Void)? = nil

    @State private var showSyncSheet = false
    @State private var toastNote: String = ""

    var body: some View {
        NavigationStack {
            Form {
                #if !targetEnvironment(macCatalyst)
                Section("Document Editing") {
                    settingsRow(icon: "pencil.tip", color: .blue) {
                        Picker("Apple Pencil Double-Tap", selection: $settings.pencilDoubleTap) {
                            ForEach(PencilDoubleTapAction.allCases) { act in
                                Text(act.title).tag(act)
                            }
                        }
                    }

                    settingsRow(icon: "hand.draw", color: .indigo) {
                        Toggle("Draw with Finger", isOn: $settings.drawWithFinger)
                    }

                    settingsRow(icon: "hand.tap", color: .purple) {
                        Toggle("2-Finger Undo / 3-Finger Redo", isOn: $settings.fingerTapUndoRedo)
                    }

                    settingsRow(icon: "waveform", color: .teal) {
                        Toggle("Haptic Feedback", isOn: $settings.hapticsEnabled)
                    }
                }
                #endif

                Section("Appearance & Reading") {
                    settingsRow(icon: "circle.lefthalf.filled", color: .blue) {
                        Picker("Theme", selection: $settings.appTheme) {
                            ForEach(AppThemeOption.allCases) { opt in
                                Text(opt.title).tag(opt)
                            }
                        }
                    }

                    settingsRow(icon: "doc.plaintext", color: .orange) {
                        Picker("Paper Mode", selection: $settings.pdfReadingMode) {
                            ForEach(PDFReadingMode.allCases) { mode in
                                Label(mode.title, systemImage: mode.systemImage).tag(mode)
                            }
                        }
                    }

                    settingsRow(icon: "sun.max.fill", color: .yellow) {
                        Toggle("Keep Screen Awake", isOn: $settings.keepScreenAwake)
                    }
                }

                Section("Tabs & Workspace") {
                    settingsRow(icon: "rectangle.topthird.inset.filled", color: .cyan) {
                        Toggle("Show Document Tabs", isOn: $settings.showTabBar)
                    }

                    settingsRow(icon: "arrow.clockwise.circle", color: .blue) {
                        Toggle("Restore Open Tabs on Launch", isOn: $settings.restoreTabsOnLaunch)
                    }

                    settingsRow(icon: "slider.horizontal.3", color: .gray) {
                        Toggle("Compact Drawing Bar", isOn: $settings.compactToolbar)
                    }

                    if !tabManager.tabs.isEmpty {
                        Button(role: .destructive) {
                            tabManager.closeAllTabs()
                            toastNote = "Closed all open tabs."
                        } label: {
                            Label("Close All Open Tabs (\(tabManager.tabs.count))", systemImage: "xmark.rectangle.on.rectangle")
                        }
                    }
                }

                Section("Cloud Sync") {
                    Button {
                        showSyncSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            settingsIconBadge("icloud.and.arrow.up", color: .green)
                            Text("Google Drive Sync & Device Key")
                                .foregroundColor(.primary)
                            Spacer()
                            HStack(spacing: 6) {
                                Circle().fill(syncDotColor).frame(width: 8, height: 8)
                                Text(syncManager.config.isConnected ? syncManager.statusText : "Off")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    settingsRow(icon: "clock.arrow.circlepath", color: .green) {
                        Picker("Live Sync Interval", selection: $settings.syncPollSeconds) {
                            Text("Fast (3.5s)").tag(3.5)
                            Text("Balanced (5s)").tag(5.0)
                            Text("Battery Saver (10s)").tag(10.0)
                            Text("Manual Only").tag(0.0)
                        }
                    }
                }

                Section("Vault & Storage") {
                    HStack(spacing: 12) {
                        settingsIconBadge("folder.fill", color: .blue)
                        Text("Active Vault Root")
                        Spacer()
                        Text(vault.vaultURL?.lastPathComponent ?? "Not Selected")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if let choose = onChooseVaultFolder {
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                choose()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                settingsIconBadge("folder.badge.gearshape", color: .blue)
                                Text("Change Vault Folder…")
                            }
                        }
                    }

                    Button {
                        vault.clearThumbnailCache()
                        toastNote = "Thumbnail cache cleared."
                    } label: {
                        HStack(spacing: 12) {
                            settingsIconBadge("sparkles", color: .orange)
                            Text("Clear Cover Cache")
                                .foregroundColor(.primary)
                        }
                    }
                }

                if !toastNote.isEmpty {
                    Section {
                        Text(toastNote)
                            .font(.caption.weight(.medium))
                            .foregroundColor(.accentColor)
                    }
                }

                Section {
                    HStack {
                        Text("Pencil Ink Native")
                            .fontWeight(.medium)
                        Spacer()
                        Text("v1.2.0")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showSyncSheet) {
                DriveSyncSettingsSheet(syncManager: syncManager, vault: vault)
                    .preferredColorScheme(settings.appTheme.preferredColorScheme)
            }
        }
    }

    private func settingsRow<Content: View>(icon: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            settingsIconBadge(icon, color: color)
            content()
        }
    }

    private func settingsIconBadge(_ systemName: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .frame(width: 28, height: 28)
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var syncDotColor: Color {
        switch syncManager.visualState {
        case .ok: return .green
        case .syncing: return .blue
        case .error: return .red
        case .disconnected: return .gray
        }
    }
}
