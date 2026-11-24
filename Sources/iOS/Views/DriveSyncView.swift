import SwiftUI
import UIKit

struct SyncStatusDotButton: View {
    @ObservedObject var syncManager: DriveSyncManager
    let action: () -> Void

    private var dotColor: Color {
        switch syncManager.visualState {
        case .ok: return DesignTokens.emerald
        case .syncing: return Color(red: 0.04, green: 0.52, blue: 1.0)
        case .error: return DesignTokens.coralRed
        case .disconnected: return Color(white: 0.56)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    if syncManager.isTransferActive && syncManager.syncProgressFraction >= 0 {
                        Circle()
                            .stroke(dotColor.opacity(0.22), lineWidth: 2.4)
                            .frame(width: 22, height: 22)
                        Circle()
                            .trim(from: 0, to: CGFloat(max(0.05, min(1.0, syncManager.syncProgressFraction))))
                            .stroke(dotColor, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 22, height: 22)
                            .animation(.easeOut(duration: 0.18), value: syncManager.syncProgressFraction)
                        Circle()
                            .fill(dotColor)
                            .frame(width: 7, height: 7)
                    } else {
                        Circle()
                            .fill(dotColor.opacity(syncManager.visualState == .syncing ? 0.34 : 0.20))
                            .frame(width: 20, height: 20)
                        Circle()
                            .fill(dotColor)
                            .frame(width: 10, height: 10)
                    }
                }
                .frame(width: 24, height: 24)

                if syncManager.isTransferActive && syncManager.syncProgressFraction >= 0 {
                    Text("\(Int((syncManager.syncProgressFraction * 100.0).rounded()))%")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(dotColor)
                }
            }
            .padding(.horizontal, syncManager.isTransferActive && syncManager.syncProgressFraction >= 0 ? 7 : 4)
            .frame(minWidth: 32, minHeight: 32)
            .background(
                Capsule()
                    .fill(syncManager.isTransferActive && syncManager.syncProgressFraction >= 0 ? dotColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Isolated, zero-idle-cost inline sync progress strip visible directly in Library & Notebook chrome
/// without opening any sheet or popover. Renders 0 pixels when idle!
struct InlineSyncProgressStrip: View {
    @ObservedObject var syncManager: DriveSyncManager
    var compact: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if syncManager.isTransferActive {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if syncManager.syncProgressFraction < 0 {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                            .font(.system(size: compact ? 11.5 : 13, weight: .semibold))
                            .foregroundColor(DesignTokens.accent(colorScheme))
                    }

                    Text(syncManager.syncPhaseLabel.isEmpty ? syncManager.statusText : syncManager.syncPhaseLabel)
                        .font(.system(size: compact ? 11 : 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    if syncManager.syncProgressFraction >= 0 {
                        Text("\(Int((syncManager.syncProgressFraction * 100.0).rounded()))%")
                            .font(.system(size: compact ? 11 : 11.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(DesignTokens.accent(colorScheme))
                    }

                    if !syncManager.syncSpeedText.isEmpty {
                        Text(syncManager.syncSpeedText)
                            .font(.system(size: compact ? 10.5 : 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }

                    Button {
                        syncManager.cancelActiveTransfer()
                        Haptics.light()
                    } label: {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: compact ? 14 : 15))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, compact ? 14 : 18)
                .padding(.vertical, compact ? 5 : 7)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(DesignTokens.accent(colorScheme).opacity(0.14))
                        let frac = syncManager.syncProgressFraction < 0
                            ? 0.28
                            : max(0.03, min(1.0, syncManager.syncProgressFraction))
                        Rectangle()
                            .fill(DesignTokens.accent(colorScheme))
                            .frame(width: geo.size.width * CGFloat(frac))
                            .animation(.easeOut(duration: 0.18), value: frac)
                    }
                }
                .frame(height: 2.5)
            }
            .background(DesignTokens.chromeSecondary(colorScheme))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct SyncStatusPopoverView: View {
    @ObservedObject var syncManager: DriveSyncManager
    let onSyncNow: () -> Void
    let onOpenSettings: () -> Void

    private var dotColor: Color {
        switch syncManager.visualState {
        case .ok: return .green
        case .syncing: return .blue
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(dotColor).frame(width: 10, height: 10)
                Text(syncManager.statusText)
                    .font(.headline)
                Spacer()
                Text(syncManager.config.driveFolder)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                row("Uploaded this session", syncManager.formatBytes(syncManager.sessionBytesUp))
                row("Downloaded this session", syncManager.formatBytes(syncManager.sessionBytesDown))
                row("Books synced", "\(syncManager.sessionBooksSynced)")
                if let last = syncManager.lastSyncedAt {
                    row("Last synced", last.formatted(date: .omitted, time: .standard))
                }
            }

            if !syncManager.syncProgressText.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(syncManager.syncProgressText)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.primary)
                }
            }

            if !syncManager.lastDiagnostic.isEmpty {
                Text(syncManager.lastDiagnostic)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }

            if !syncManager.lastError.isEmpty {
                Text(syncManager.lastError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                if syncManager.config.isConnected {
                    if syncManager.isTransferActive {
                        Button {
                            syncManager.cancelActiveTransfer()
                        } label: {
                            Text("Pause (Resumable)")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            onSyncNow()
                        } label: {
                            Text(syncManager.visualState == .syncing ? "Syncing…" : "Sync Now")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(syncManager.visualState == .syncing)
                    }
                }
                Button("Settings") {
                    onOpenSettings()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: syncManager.config.isConnected ? nil : .infinity)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundColor(.secondary)
            Spacer()
            Text(v).font(.caption.weight(.semibold))
        }
    }
}

struct DriveSyncSettingsSheet: View {
    @ObservedObject var syncManager: DriveSyncManager
    @ObservedObject var vault: VaultManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var manualDeviceKey: String = ""
    @State private var showManualKeyField: Bool = false
    @State private var authVerifier: String = ""
    @State private var pastedRedirect: String = ""
    @State private var feedbackMessage: String = ""
    @State private var feedbackIsError: Bool = false
    @State private var isFinishingAuth = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection Status") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(syncManager.config.isConnected ? syncManager.statusText : "Not Connected")
                            .foregroundColor(syncManager.config.isConnected ? .green : .secondary)
                            .fontWeight(.semibold)
                    }
                    if let vName = vault.vaultURL?.lastPathComponent {
                        HStack {
                            Text("Active Vault Root")
                            Spacer()
                            Text(vName)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    if !syncManager.config.deviceLabel.isEmpty {
                        HStack {
                            Text("Device ID")
                            Spacer()
                            Text(syncManager.config.deviceLabel)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }
                    if VaultManager.isRunningInLiveContainer {
                        HStack {
                            Text("Environment")
                            Spacer()
                            Text("LiveContainer")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                    if !syncManager.syncProgressText.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(syncManager.syncProgressText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let last = syncManager.lastSyncedAt {
                        HStack {
                            Text("Last Synced")
                            Spacer()
                            Text(last.formatted(date: .abbreviated, time: .shortened))
                                .foregroundColor(.secondary)
                        }
                    }
                    if !syncManager.lastError.isEmpty {
                        Text(syncManager.lastError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                // 1-Tap Device Key Linking (Exact match to Obsidian Pencil Ink's PENCIL-INK-DEVICE: key!)
                Section(
                    header: Text("Link Device (Copy / Paste Device Key)"),
                    footer: Text("In Obsidian on your Mac, PC, or iPad, open Pencil Ink settings and tap Copy Device Key. Then tap Paste Device Key here for instant 1-tap sign-in.")
                ) {
                    Button {
                        if let clip = UIPasteboard.general.string, !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let res = syncManager.applyDeviceKey(clip)
                            feedbackMessage = res.message
                            feedbackIsError = !res.ok
                            if res.ok && syncManager.config.isConnected {
                                showManualKeyField = false
                                Task {
                                    let check = await syncManager.verifyDriveConnection()
                                    feedbackMessage = check.message
                                    feedbackIsError = !check.ok
                                    if check.ok && vault.vaultURL != nil {
                                        let r = await syncManager.syncVault(vault: vault, force: true)
                                        feedbackMessage = "Connected! Downloaded \(r.downloadedPDFs) PDFs, uploaded \(r.uploadedPDFs), synced \(r.syncedBooks) notes."
                                    }
                                }
                            } else if !res.ok {
                                showManualKeyField = true
                            }
                        } else {
                            showManualKeyField = true
                            feedbackMessage = "Clipboard didn't contain a Device Key — paste it into the box below."
                            feedbackIsError = false
                        }
                    } label: {
                        Label("Paste Device Key from Clipboard", systemImage: "doc.on.clipboard")
                            .fontWeight(.semibold)
                    }

                    Button {
                        showManualKeyField.toggle()
                    } label: {
                        Label(showManualKeyField ? "Hide Manual Key Box" : "Enter Device Key Manually…", systemImage: "keyboard")
                            .foregroundColor(.secondary)
                    }

                    if showManualKeyField {
                        TextField("PENCIL-INK-DEVICE:...", text: $manualDeviceKey, axis: .vertical)
                            .lineLimit(2...5)
                            .font(.system(size: 12, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Button {
                            let res = syncManager.applyDeviceKey(manualDeviceKey)
                            feedbackMessage = res.message
                            feedbackIsError = !res.ok
                            if res.ok {
                                manualDeviceKey = ""
                                if syncManager.config.isConnected {
                                    showManualKeyField = false
                                    Task {
                                        let check = await syncManager.verifyDriveConnection()
                                        feedbackMessage = check.message
                                        feedbackIsError = !check.ok
                                        if check.ok && vault.vaultURL != nil {
                                            let r = await syncManager.syncVault(vault: vault, force: true)
                                            feedbackMessage = "Connected! Downloaded \(r.downloadedPDFs) PDFs, uploaded \(r.uploadedPDFs), synced \(r.syncedBooks) notes."
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text("Apply Device Key & Connect")
                                .fontWeight(.semibold)
                        }
                        .disabled(manualDeviceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Button {
                        if let key = syncManager.encodeDeviceKey() {
                            UIPasteboard.general.string = key
                            feedbackMessage = syncManager.config.isConnected
                                ? "Device Key copied! Paste it into Pencil Ink settings on another device."
                                : "App Credentials Key copied to clipboard."
                            feedbackIsError = false
                        } else {
                            feedbackMessage = "Connect Google Drive or enter Client ID & Secret before copying a Device Key."
                            feedbackIsError = true
                        }
                    } label: {
                        Label("Copy Device Key", systemImage: "key.fill")
                    }
                }

                if !feedbackMessage.isEmpty {
                    Section {
                        Text(feedbackMessage)
                            .font(.subheadline)
                            .foregroundColor(feedbackIsError ? .red : .green)
                    }
                }

                if syncManager.config.isConnected {
                    Section("Sync Actions") {
                        Button {
                            Task {
                                let check = await syncManager.verifyDriveConnection()
                                feedbackMessage = check.message
                                feedbackIsError = !check.ok
                            }
                        } label: {
                            Label("Test Google Drive Connection", systemImage: "checkmark.icloud")
                        }
                        .disabled(syncManager.visualState == .syncing)

                        Button {
                            Task {
                                let r = await syncManager.syncVault(vault: vault, force: true)
                                if syncManager.lastError.isEmpty {
                                    feedbackMessage = "Vault synced! Downloaded \(r.downloadedPDFs) new PDF\(r.downloadedPDFs == 1 ? "" : "s"), uploaded \(r.uploadedPDFs), synced \(r.syncedBooks) note\(r.syncedBooks == 1 ? "" : "s")."
                                    feedbackIsError = false
                                } else {
                                    feedbackMessage = syncManager.lastError
                                    feedbackIsError = true
                                }
                            }
                        } label: {
                            Label("Sync Vault & Download New PDFs Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(syncManager.visualState == .syncing || vault.vaultURL == nil)

                        Button {
                            Task {
                                let res = await syncManager.purgeExpiredDriveTrash(force: true)
                                feedbackMessage = "Drive Trash (.PencilInk-Trash): purged \(res.purged) expired (>120d), \(res.remaining) remaining."
                                feedbackIsError = false
                            }
                        } label: {
                            HStack {
                                Label("Purge Expired Drive Trash (>120d)", systemImage: "clock.arrow.circlepath")
                                Spacer()
                                if syncManager.trashedItemsCount > 0 {
                                    Text("\(syncManager.trashedItemsCount)")
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .disabled(syncManager.isTransferActive)

                        Button(role: .destructive) {
                            Task {
                                let n = await syncManager.emptyDriveTrashNow()
                                feedbackMessage = "Permanently deleted \(n) item\(n == 1 ? "" : "s") from .PencilInk-Trash."
                                feedbackIsError = false
                            }
                        } label: {
                            Label("Empty Drive Trash Now", systemImage: "trash.slash")
                        }
                        .disabled(syncManager.isTransferActive)

                        Button(role: .destructive) {
                            syncManager.disconnect()
                            feedbackMessage = "Disconnected from Google Drive."
                            feedbackIsError = false
                        } label: {
                            Label("Disconnect Google Drive", systemImage: "xmark.circle")
                        }
                    }
                }

                Section("Google Drive Configuration") {
                    TextField("Google Drive Folder", text: $syncManager.config.driveFolder)
                        .autocorrectionDisabled()
                    TextField("OAuth Client ID", text: $syncManager.config.clientId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("OAuth Client Secret", text: $syncManager.config.clientSecret)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Toggle("Auto-Sync Vault & Annotations", isOn: $syncManager.config.autoSync)
                    Toggle("Download & Upload PDF Files", isOn: $syncManager.config.syncPDFs)
                }

                if !syncManager.config.isConnected {
                    Section(
                        header: Text("Or Sign In Manually with Google"),
                        footer: Text("1. Tap Open Google Sign-In and approve access.\n2. Copy the 127.0.0.1 address from Safari, paste it below, and tap Finish Sign-In.")
                    ) {
                        Button {
                            if let auth = syncManager.beginOAuth() {
                                authVerifier = auth.verifier
                                feedbackMessage = "Browser opened. Approve access, then copy the 127.0.0.1 URL and paste it below."
                                feedbackIsError = false
                                openURL(auth.url)
                            } else {
                                feedbackMessage = "Enter your OAuth Client ID (or paste a Device Key above) first."
                                feedbackIsError = true
                            }
                        } label: {
                            Label("Open Google Sign-In", systemImage: "safari")
                                .fontWeight(.semibold)
                        }

                        if !authVerifier.isEmpty {
                            TextField("Paste http://127.0.0.1:8765/?code=... here", text: $pastedRedirect)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button {
                                isFinishingAuth = true
                                Task {
                                    do {
                                        try await syncManager.finishOAuth(pasted: pastedRedirect, verifier: authVerifier)
                                        feedbackMessage = "Connected to Google Drive!"
                                        feedbackIsError = false
                                        authVerifier = ""
                                        pastedRedirect = ""
                                    } catch {
                                        feedbackMessage = error.localizedDescription
                                        feedbackIsError = true
                                    }
                                    isFinishingAuth = false
                                }
                            } label: {
                                Text(isFinishingAuth ? "Connecting…" : "Finish Sign-In")
                                    .fontWeight(.semibold)
                            }
                            .disabled(isFinishingAuth || pastedRedirect.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            .navigationTitle("Google Drive Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        syncManager.saveConfig()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
