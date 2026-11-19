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
                // 1. Reading & Workspace Appearance
                Section("Appearance & Reading") {
                    Picker("App Theme", selection: $settings.appTheme) {
                        ForEach(AppThemeOption.allCases) { opt in
                            Text(opt.title).tag(opt)
                        }
                    }

                    Picker("PDF Paper Mode", selection: $settings.pdfReadingMode) {
                        ForEach(PDFReadingMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode)
                        }
                    }

                    Toggle("Show Document Tab Bar", isOn: $settings.showTabBar)
                    Toggle("Restore Open Tabs on Launch", isOn: $settings.restoreTabsOnLaunch)
                    Toggle("Compact Tool Dock", isOn: $settings.compactToolbar)
                }

                // 2. Apple Pencil & Gestures
                Section(
                    header: Text("Apple Pencil & Gestures"),
                    footer: Text("Keep Draw with Finger turned off for strict hardware palm rejection when writing with a stylus.")
                ) {
                    Picker("Pencil Double-Tap", selection: $settings.pencilDoubleTap) {
                        ForEach(PencilDoubleTapAction.allCases) { act in
                            Text(act.title).tag(act)
                        }
                    }
                    Toggle("Draw with Finger", isOn: $settings.drawWithFinger)
                    Toggle("2-Finger Undo / 3-Finger Redo", isOn: $settings.fingerTapUndoRedo)
                    Toggle("Haptic Feedback", isOn: $settings.hapticsEnabled)
                    Toggle("Keep Screen Awake While Studying", isOn: $settings.keepScreenAwake)
                }

                // 3. Google Drive CRDT Sync
                Section("Google Drive Sync") {
                    Button {
                        showSyncSheet = true
                    } label: {
                        HStack {
                            Label("Google Drive Account & Device Key", systemImage: "icloud.and.arrow.up")
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(syncDotColor)
                                    .frame(width: 8, height: 8)
                                Text(syncManager.config.isConnected ? syncManager.statusText : "Not Connected")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .foregroundColor(.primary)

                    Picker("Live Sync Check Interval", selection: $settings.syncPollSeconds) {
                        Text("Fast (3.5s)").tag(3.5)
                        Text("Balanced (5s)").tag(5.0)
                        Text("Battery Saver (10s)").tag(10.0)
                        Text("Manual Only").tag(0.0)
                    }
                }

                // 4. Vault & Storage
                Section("Vault & Storage") {
                    HStack {
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
                            Label("Change Vault Folder…", systemImage: "folder.badge.gearshape")
                        }
                    }

                    if !tabManager.tabs.isEmpty {
                        Button(role: .destructive) {
                            tabManager.closeAllTabs()
                            toastNote = "Closed all open tabs."
                        } label: {
                            Label("Close All Open Tabs (\(tabManager.tabs.count))", systemImage: "xmark.rectangle.on.rectangle")
                        }
                    }

                    Button {
                        vault.clearThumbnailCache()
                        toastNote = "Cover thumbnail cache cleared."
                    } label: {
                        Label("Clear Thumbnail Cache", systemImage: "sparkles")
                    }
                }

                if !toastNote.isEmpty {
                    Section {
                        Text(toastNote)
                            .font(.caption.weight(.medium))
                            .foregroundColor(.blue)
                    }
                }

                Section {
                    HStack {
                        Text("Pencil Ink Native")
                            .fontWeight(.semibold)
                        Spacer()
                        Text("v1.0.0")
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

    private var syncDotColor: Color {
        switch syncManager.visualState {
        case .ok: return .green
        case .syncing: return .blue
        case .error: return .red
        case .disconnected: return .gray
        }
    }
}
