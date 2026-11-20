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
                Section("Document Editing") {
                    settingsRow(icon: "hand.raised.fill", color: .blue) {
                        Toggle("Start PDFs in Scroll / Hand Mode", isOn: $settings.startInHandMode)
                    }

                    #if !targetEnvironment(macCatalyst)
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
                    #endif
                }

                Section("Toolbar Customization") {
                    settingsRow(icon: "sidebar.left", color: .indigo) {
                        Picker("Toolbar Position", selection: $settings.toolbarPosition) {
                            ForEach(ToolbarPosition.allCases) { pos in
                                Text(pos.title).tag(pos)
                            }
                        }
                    }

                    settingsRow(icon: "slider.horizontal.3", color: .gray) {
                        Toggle("Compact Drawing Bar", isOn: $settings.compactToolbar)
                    }

                    NavigationLink {
                        ToolbarToolsCustomizationView()
                    } label: {
                        HStack(spacing: 12) {
                            settingsIconBadge("wrench.and.screwdriver.fill", color: .blue)
                            Text("Show / Hide Toolbar Tools")
                            Spacer()
                            let enabledCount = DrawingTool.allCases.filter { settings.isToolVisible($0) }.count
                            Text("\(enabledCount)/\(DrawingTool.allCases.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }

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

                    #if !targetEnvironment(macCatalyst)
                    settingsRow(icon: "sun.max.fill", color: .yellow) {
                        Toggle("Keep Screen Awake", isOn: $settings.keepScreenAwake)
                    }
                    #endif
                }

                Section("Tabs & Workspace") {
                    settingsRow(icon: "rectangle.topthird.inset.filled", color: .cyan) {
                        Toggle("Show Document Tabs", isOn: $settings.showTabBar)
                    }

                    settingsRow(icon: "arrow.clockwise.circle", color: .blue) {
                        Toggle("Restore Open Tabs on Launch", isOn: $settings.restoreTabsOnLaunch)
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

                Section(
                    header: Text("Cloud Sync"),
                    footer: Text("Smart Sync never interrupts while you write or type, batches uploads 4 seconds after you finish, and checks Google Drive when you return or step away.")
                ) {
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

                    settingsRow(icon: "bolt.horizontal.icloud.fill", color: .green) {
                        Picker("Sync Mode", selection: $settings.syncMode) {
                            ForEach(SyncBehaviorMode.allCases) { m in
                                Text(m.title).tag(m)
                            }
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
                        Text("v1.3.0")
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

/// Dedicated Toolbar Customization sub-screen (add/remove any tool & reset layout).
struct ToolbarToolsCustomizationView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section(
                header: Text("Visible Drawing Tools"),
                footer: Text("Toggle tools on or off to keep your toolbar minimal. At least one tool must remain visible.")
            ) {
                ForEach(DrawingTool.allCases) { tool in
                    Toggle(isOn: Binding(
                        get: { settings.isToolVisible(tool) },
                        set: { settings.setToolVisible(tool, visible: $0) }
                    )) {
                        Label(tool.displayName, systemImage: tool.settingsIcon)
                    }
                }
            }

            Section {
                Button("Reset Toolbar to Defaults") {
                    settings.resetToolbarDefaults()
                }
                .foregroundColor(.accentColor)
            }
        }
        .navigationTitle("Toolbar Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}
