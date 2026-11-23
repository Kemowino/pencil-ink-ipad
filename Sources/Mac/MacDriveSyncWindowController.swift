import AppKit
import Combine

/// Pure AppKit Google Drive Sync & Device Key Window (100% compatible with iPad & Obsidian `PENCIL-INK-DEVICE:` keys!).
@MainActor
final class MacDriveSyncWindowController: NSWindowController, NSWindowDelegate {
    let syncManager: DriveSyncManager
    let vault: VaultManager
    var onWindowClosed: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let detailsLabel = NSTextField(labelWithString: "")
    private let feedbackLabel = NSTextField(labelWithString: "")

    private let deviceKeyField = NSTextField()
    private let driveFolderField = NSTextField()
    private let clientIdField = NSTextField()
    private let clientSecretField = NSSecureTextField()
    private let syncModePopup = NSPopUpButton()
    private let autoSyncCheck = NSButton(checkboxWithTitle: "Auto-sync annotations & vault", target: nil, action: nil)
    private let syncPDFsCheck = NSButton(checkboxWithTitle: "Download & upload PDF files", target: nil, action: nil)

    private let redirectField = NSTextField()
    private let finishOAuthBtn = NSButton(title: "Finish Sign-In", target: nil, action: nil)
    private let testBtn = NSButton(title: "Test Connection", target: nil, action: nil)
    private let syncVaultBtn = NSButton(title: "Sync Vault Now", target: nil, action: nil)
    private let disconnectBtn = NSButton(title: "Disconnect", target: nil, action: nil)

    private var authVerifier: String = ""
    private var cancellables = Set<AnyCancellable>()

    init(syncManager: DriveSyncManager, vault: VaultManager) {
        self.syncManager = syncManager
        self.vault = vault
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 590),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Google Drive Sync & Device Key"
        win.center()
        super.init(window: win)
        win.delegate = self
        setupUI()
        loadFieldsFromConfig()
        bindStatus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let root = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18)
        ])

        func header(_ title: String) -> NSTextField {
            let tf = NSTextField(labelWithString: title)
            tf.font = NSFont.systemFont(ofSize: 13, weight: .bold)
            return tf
        }

        func separator() -> NSBox {
            let b = NSBox()
            b.boxType = .separator
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 500).isActive = true
            return b
        }

        // 1. Status Section
        stack.addArrangedSubview(header("Connection Status"))
        statusLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        stack.addArrangedSubview(statusLabel)

        detailsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.maximumNumberOfLines = 3
        detailsLabel.preferredMaxLayoutWidth = 500
        stack.addArrangedSubview(detailsLabel)

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        testBtn.bezelStyle = .rounded
        testBtn.target = self
        testBtn.action = #selector(testConnection)
        syncVaultBtn.bezelStyle = .rounded
        syncVaultBtn.target = self
        syncVaultBtn.action = #selector(syncVaultNow)
        disconnectBtn.bezelStyle = .rounded
        disconnectBtn.contentTintColor = .systemRed
        disconnectBtn.target = self
        disconnectBtn.action = #selector(disconnectDrive)
        actionRow.addArrangedSubview(testBtn)
        actionRow.addArrangedSubview(syncVaultBtn)
        actionRow.addArrangedSubview(disconnectBtn)
        stack.addArrangedSubview(actionRow)

        stack.addArrangedSubview(separator())

        // 2. 1-Click Device Key Section
        stack.addArrangedSubview(header("Link Device (Obsidian / iPad Device Key)"))
        let dkHint = NSTextField(labelWithString: "Copy your PENCIL-INK-DEVICE: key from Obsidian or your iPad and click Paste & Connect.")
        dkHint.font = NSFont.systemFont(ofSize: 11.5)
        dkHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(dkHint)

        deviceKeyField.placeholderString = "PENCIL-INK-DEVICE:..."
        deviceKeyField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        deviceKeyField.translatesAutoresizingMaskIntoConstraints = false
        deviceKeyField.widthAnchor.constraint(equalToConstant: 500).isActive = true
        stack.addArrangedSubview(deviceKeyField)

        let dkButtons = NSStackView()
        dkButtons.orientation = .horizontal
        dkButtons.spacing = 8

        let pasteBtn = NSButton(title: "Paste from Clipboard & Connect", target: self, action: #selector(pasteAndConnectKey))
        pasteBtn.bezelStyle = .rounded
        let applyBtn = NSButton(title: "Apply Key", target: self, action: #selector(applyManualKey))
        applyBtn.bezelStyle = .rounded
        let copyBtn = NSButton(title: "Copy This Device Key", target: self, action: #selector(copyDeviceKey))
        copyBtn.bezelStyle = .rounded
        dkButtons.addArrangedSubview(pasteBtn)
        dkButtons.addArrangedSubview(applyBtn)
        dkButtons.addArrangedSubview(copyBtn)
        stack.addArrangedSubview(dkButtons)

        feedbackLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        feedbackLabel.maximumNumberOfLines = 2
        feedbackLabel.preferredMaxLayoutWidth = 500
        stack.addArrangedSubview(feedbackLabel)

        stack.addArrangedSubview(separator())

        // 3. Configuration & Sync Behavior
        stack.addArrangedSubview(header("Sync Behavior & Drive Folder"))

        func labeledRow(_ label: String, control: NSView) -> NSStackView {
            let r = NSStackView()
            r.orientation = .horizontal
            r.spacing = 8
            let lbl = NSTextField(labelWithString: label)
            lbl.font = NSFont.systemFont(ofSize: 12)
            lbl.alignment = .right
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.widthAnchor.constraint(equalToConstant: 125).isActive = true
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 365).isActive = true
            r.addArrangedSubview(lbl)
            r.addArrangedSubview(control)
            return r
        }

        for m in MacSyncMode.allCases { syncModePopup.addItem(withTitle: m.title) }
        syncModePopup.target = self
        syncModePopup.action = #selector(syncModeChanged)
        stack.addArrangedSubview(labeledRow("Sync Mode:", control: syncModePopup))

        driveFolderField.placeholderString = "Obsidian Vault"
        stack.addArrangedSubview(labeledRow("Drive Folder:", control: driveFolderField))

        let checksRow = NSStackView()
        checksRow.orientation = .horizontal
        checksRow.spacing = 16
        checksRow.addArrangedSubview(autoSyncCheck)
        checksRow.addArrangedSubview(syncPDFsCheck)
        stack.addArrangedSubview(checksRow)

        stack.addArrangedSubview(separator())

        // 4. Manual OAuth2 Fallback
        stack.addArrangedSubview(header("Manual Google OAuth (Optional)"))
        clientIdField.placeholderString = "Google OAuth Client ID"
        clientSecretField.placeholderString = "Google OAuth Client Secret"
        stack.addArrangedSubview(labeledRow("Client ID:", control: clientIdField))
        stack.addArrangedSubview(labeledRow("Client Secret:", control: clientSecretField))

        let oauthRow = NSStackView()
        oauthRow.orientation = .horizontal
        oauthRow.spacing = 8
        let openSignInBtn = NSButton(title: "Open Google Sign-In", target: self, action: #selector(openGoogleSignIn))
        openSignInBtn.bezelStyle = .rounded
        redirectField.placeholderString = "Paste http://127.0.0.1:8765/?code=... here"
        redirectField.translatesAutoresizingMaskIntoConstraints = false
        redirectField.widthAnchor.constraint(equalToConstant: 245).isActive = true
        finishOAuthBtn.bezelStyle = .rounded
        finishOAuthBtn.target = self
        finishOAuthBtn.action = #selector(finishGoogleSignIn)
        oauthRow.addArrangedSubview(openSignInBtn)
        oauthRow.addArrangedSubview(redirectField)
        oauthRow.addArrangedSubview(finishOAuthBtn)
        stack.addArrangedSubview(oauthRow)

        // Bottom Save & Close row
        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        let sp = NSView()
        sp.translatesAutoresizingMaskIntoConstraints = false
        sp.widthAnchor.constraint(equalToConstant: 370).isActive = true
        let saveCloseBtn = NSButton(title: "Save & Close", target: self, action: #selector(saveAndClose))
        saveCloseBtn.bezelStyle = .rounded
        saveCloseBtn.keyEquivalent = "\r"
        bottomRow.addArrangedSubview(sp)
        bottomRow.addArrangedSubview(saveCloseBtn)
        stack.addArrangedSubview(bottomRow)
    }

    private func loadFieldsFromConfig() {
        driveFolderField.stringValue = syncManager.config.driveFolder
        clientIdField.stringValue = syncManager.config.clientId
        clientSecretField.stringValue = syncManager.config.clientSecret
        autoSyncCheck.state = syncManager.config.autoSync ? .on : .off
        syncPDFsCheck.state = syncManager.config.syncPDFs ? .on : .off
        if let idx = MacSyncMode.allCases.firstIndex(of: MacPreferences.shared.syncMode) {
            syncModePopup.selectItem(at: idx)
        }
        refreshStatusUI()
    }

    private func bindStatus() {
        syncManager.$statusText
            .combineLatest(syncManager.$syncProgressText, syncManager.$lastDiagnostic, syncManager.$lastError)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
                self?.refreshStatusUI()
            }
            .store(in: &cancellables)
    }

    private func refreshStatusUI() {
        let connected = syncManager.config.isConnected
        statusLabel.stringValue = connected
            ? "Connected · \(syncManager.statusText) (Device: \(syncManager.config.deviceLabel))"
            : "Not Connected"
        statusLabel.textColor = connected ? .systemGreen : .secondaryLabelColor

        var parts: [String] = []
        if let vName = vault.vaultURL?.lastPathComponent { parts.append("Vault: \(vName)") }
        parts.append("↑\(syncManager.formatBytes(syncManager.sessionBytesUp))  ↓\(syncManager.formatBytes(syncManager.sessionBytesDown))")
        if !syncManager.syncProgressText.isEmpty { parts.append(syncManager.syncProgressText) }
        else if !syncManager.lastDiagnostic.isEmpty { parts.append(syncManager.lastDiagnostic) }
        if !syncManager.lastError.isEmpty { parts.append("Error: \(syncManager.lastError)") }
        detailsLabel.stringValue = parts.joined(separator: "\n")

        testBtn.isEnabled = connected && syncManager.visualState != .syncing
        syncVaultBtn.isEnabled = connected && vault.vaultURL != nil && syncManager.visualState != .syncing
        disconnectBtn.isEnabled = connected
    }

    private func commitFieldsToConfig() {
        syncManager.config.driveFolder = driveFolderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        syncManager.config.clientId = clientIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        syncManager.config.clientSecret = clientSecretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        syncManager.config.autoSync = (autoSyncCheck.state == .on)
        syncManager.config.syncPDFs = (syncPDFsCheck.state == .on)
        syncManager.saveConfig()
    }

    private func setFeedback(_ msg: String, isError: Bool) {
        feedbackLabel.stringValue = msg
        feedbackLabel.textColor = isError ? .systemRed : .systemGreen
    }

    @objc private func syncModeChanged() {
        let idx = max(0, min(MacSyncMode.allCases.count - 1, syncModePopup.indexOfSelectedItem))
        MacPreferences.shared.syncMode = MacSyncMode.allCases[idx]
    }

    @objc private func pasteAndConnectKey() {
        guard let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clip.isEmpty else {
            setFeedback("Clipboard is empty. Copy a PENCIL-INK-DEVICE: key first.", isError: true)
            return
        }
        deviceKeyField.stringValue = clip
        applyKeyString(clip)
    }

    @objc private func applyManualKey() {
        let raw = deviceKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            setFeedback("Paste a PENCIL-INK-DEVICE: key first.", isError: true)
            return
        }
        applyKeyString(raw)
    }

    private func applyKeyString(_ raw: String) {
        let res = syncManager.applyDeviceKey(raw)
        setFeedback(res.message, isError: !res.ok)
        loadFieldsFromConfig()
        if res.ok {
            deviceKeyField.stringValue = ""
            if syncManager.config.isConnected {
                Task {
                    let check = await syncManager.verifyDriveConnection()
                    setFeedback(check.message, isError: !check.ok)
                    if check.ok && vault.vaultURL != nil {
                        let r = await syncManager.syncVault(vault: vault, force: true)
                        setFeedback("Connected! ↓\(r.downloadedPDFs) PDFs, ↑\(r.uploadedPDFs) uploaded, \(r.syncedBooks) notes synced.", isError: false)
                    }
                }
            }
        }
    }

    @objc private func copyDeviceKey() {
        commitFieldsToConfig()
        if let key = syncManager.encodeDeviceKey() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key, forType: .string)
            setFeedback("Device Key copied to clipboard!", isError: false)
        } else {
            setFeedback("Connect Google Drive or enter Client ID & Secret first.", isError: true)
        }
    }

    @objc private func testConnection() {
        commitFieldsToConfig()
        Task {
            let res = await syncManager.verifyDriveConnection()
            setFeedback(res.message, isError: !res.ok)
        }
    }

    @objc private func syncVaultNow() {
        commitFieldsToConfig()
        Task {
            let r = await syncManager.syncVault(vault: vault, force: true)
            if syncManager.lastError.isEmpty {
                setFeedback("Vault synced! ↓\(r.downloadedPDFs) PDFs, ↑\(r.uploadedPDFs) uploaded, \(r.syncedBooks) notes synced.", isError: false)
            } else {
                setFeedback(syncManager.lastError, isError: true)
            }
        }
    }

    @objc private func disconnectDrive() {
        syncManager.disconnect()
        loadFieldsFromConfig()
        setFeedback("Disconnected from Google Drive.", isError: false)
    }

    @objc private func openGoogleSignIn() {
        commitFieldsToConfig()
        guard let auth = syncManager.beginOAuth() else {
            setFeedback("Enter your OAuth Client ID (or paste a Device Key) first.", isError: true)
            return
        }
        authVerifier = auth.verifier
        NSWorkspace.shared.open(auth.url)
        setFeedback("Browser opened. Approve access, then paste the 127.0.0.1 redirect URL and click Finish Sign-In.", isError: false)
    }

    @objc private func finishGoogleSignIn() {
        guard !authVerifier.isEmpty else {
            setFeedback("Click Open Google Sign-In first.", isError: true)
            return
        }
        let pasted = redirectField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty else {
            setFeedback("Paste the http://127.0.0.1:8765/?code=... URL first.", isError: true)
            return
        }
        finishOAuthBtn.isEnabled = false
        Task {
            do {
                try await syncManager.finishOAuth(pasted: pasted, verifier: authVerifier)
                authVerifier = ""
                redirectField.stringValue = ""
                loadFieldsFromConfig()
                setFeedback("Connected to Google Drive!", isError: false)
            } catch {
                setFeedback(error.localizedDescription, isError: true)
            }
            finishOAuthBtn.isEnabled = true
        }
    }

    @objc private func saveAndClose() {
        commitFieldsToConfig()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        cancellables.removeAll()
        onWindowClosed?()
    }
}
