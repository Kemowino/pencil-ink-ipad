import SwiftUI
import UIKit

struct SyncStatusDotButton: View {
    @ObservedObject var syncManager: DriveSyncManager
    let action: () -> Void
    @State private var pulse = false

    private var dotColor: Color {
        switch syncManager.visualState {
        case .ok: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .syncing: return Color(red: 0.04, green: 0.52, blue: 1.0)
        case .error: return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .disconnected: return Color(white: 0.56)
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(dotColor.opacity(0.24))
                    .frame(width: 22, height: 22)
                    .scaleEffect(syncManager.visualState == .syncing && pulse ? 1.18 : 0.92)
                Circle()
                    .fill(dotColor)
                    .frame(width: 11, height: 11)
            }
            .frame(width: 34, height: 34)
        }
        .onAppear {
            updatePulseState()
        }
        .onChange(of: syncManager.visualState) { _ in
            updatePulseState()
        }
    }

    private func updatePulseState() {
        if syncManager.visualState == .syncing {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                pulse = false
            }
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
                    Button {
                        onSyncNow()
                    } label: {
                        Text(syncManager.visualState == .syncing ? "Syncing…" : "Sync Now")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(syncManager.visualState == .syncing)
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
