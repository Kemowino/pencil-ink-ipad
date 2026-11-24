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
    @State private var cacheSizeLabel: String = ""

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
                            Text("Reorder & Show/Hide Tools")
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

                    settingsRow(icon: "battery.100.bolt", color: .green) {
                        Picker("PDF Render Quality", selection: $settings.pdfRenderQuality) {
                            ForEach(PDFRenderQuality.allCases) { q in
                                Text(q.title).tag(q)
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
                            Label("Close All Open Tabs (\(tabManager.tabs.count))", systemImage: "xmark.square")
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

                    if !vault.isUsingLocalFallback {
                        Button {
                            vault.useLocalDocumentsFolder()
                            toastNote = "Switched to \(VaultManager.localFolderDisplayName)."
                        } label: {
                            HStack(spacing: 12) {
                                settingsIconBadge("internaldrive", color: .indigo)
                                Text("Use \(VaultManager.localFolderDisplayName)")
                                    .foregroundColor(.primary)
                            }
                        }
                    }

                    Button {
                        vault.clearThumbnailCache {
                            cacheSizeLabel = "0 B"
                            toastNote = "Cover & page raster caches cleared."
                        }
                    } label: {
                        HStack(spacing: 12) {
                            settingsIconBadge("sparkles", color: .orange)
                            Text("Clear Cover & Page Cache")
                                .foregroundColor(.primary)
                            Spacer()
                            if !cacheSizeLabel.isEmpty {
                                Text(cacheSizeLabel)
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onAppear {
                        vault.computeTotalCacheSizeBytes { bytes in
                            cacheSizeLabel = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
                        Text("v3.5.0")
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

/// Dedicated Toolbar Customization sub-screen: reorder tools (drag or up/down arrows), toggle visibility, & reset.
struct ToolbarToolsCustomizationView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let tools = settings.orderedTools
        List {
            Section(
                header: Text("Tool Order & Visibility"),
                footer: Text("Drag rows or use the arrows to arrange tools in any order. Toggle switches to show or hide tools.")
            ) {
                ForEach(Array(tools.enumerated()), id: \.element.id) { idx, tool in
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Button {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    settings.moveTool(tool, offset: -1)
                                }
                                Haptics.selection()
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundColor(idx == 0 ? .secondary.opacity(0.28) : .secondary)
                                    .frame(width: 24, height: 26)
                                    .background(Color.primary.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(idx == 0)

                            Button {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    settings.moveTool(tool, offset: 1)
                                }
                                Haptics.selection()
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundColor(idx == tools.count - 1 ? .secondary.opacity(0.28) : .secondary)
                                    .frame(width: 24, height: 26)
                                    .background(Color.primary.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(idx == tools.count - 1)
                        }

                        Label(tool.displayName, systemImage: tool.settingsIcon)
                            .foregroundColor(settings.isToolVisible(tool) ? .primary : .secondary)

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { settings.isToolVisible(tool) },
                            set: { settings.setToolVisible(tool, visible: $0) }
                        ))
                        .labelsHidden()
                    }
                    .padding(.vertical, 2)
                }
                .onMove { indices, newOffset in
                    settings.moveTools(from: indices, to: newOffset)
                }
            }

            Section {
                Button("Reset Toolbar to Defaults") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        settings.resetToolbarDefaults()
                    }
                    Haptics.light()
                }
                .foregroundColor(.accentColor)
            }
        }
        .navigationTitle("Toolbar Tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }
}
