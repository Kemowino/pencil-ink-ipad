import SwiftUI

/// Goodnotes-style modal presented when a file is shared to Pencil Ink via the iPadOS Share Sheet.
/// Shows a live page-1 preview, lets the user rename the file, pick or create a destination folder in the Vault,
/// saves the PDF, syncs it to Google Drive, and immediately opens it in a new tab!
struct IncomingImportSheet: View {
    let incoming: PendingIncomingFile

    @EnvironmentObject var vault: VaultManager
    @EnvironmentObject var syncManager: DriveSyncManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var incomingFiles: IncomingFileManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var documentTitle: String = ""
    @State private var selectedFolder: String = ""
    @State private var folderFilter: String = ""
    @State private var showNewFolderAlert: Bool = false
    @State private var newFolderName: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String = ""

    private var filteredFolders: [FolderItem] {
        let q = folderFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = vault.allFolders.sorted {
            $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }
        if q.isEmpty { return sorted }
        return sorted.filter {
            $0.name.lowercased().contains(q) || $0.relativePath.lowercased().contains(q)
        }
    }

    private var destinationDisplayName: String {
        if selectedFolder.isEmpty {
            return vault.vaultURL?.lastPathComponent ?? "Documents"
        }
        return (selectedFolder as NSString).lastPathComponent
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    // 1. Document Preview & Rename Card
                    Section {
                        HStack(alignment: .center, spacing: 14) {
                            Group {
                                if let img = incoming.previewImage {
                                    Image(uiImage: img)
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fit)
                                        .background(Color.white)
                                } else {
                                    ZStack {
                                        Color.white
                                        Image(systemName: "doc.richtext")
                                            .font(.system(size: 24, weight: .light))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .frame(width: 58, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(DesignTokens.hairline(colorScheme), lineWidth: 0.9)
                            )

                            VStack(alignment: .leading, spacing: 6) {
                                Text("DOCUMENT NAME")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.secondary)
                                TextField("Document title", text: $documentTitle)
                                    .font(.system(size: 15.5, weight: .semibold))
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color.primary.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                HStack(spacing: 6) {
                                    Label(
                                        "\(incoming.pageCount) \(incoming.pageCount == 1 ? "page" : "pages")",
                                        systemImage: incoming.wasConvertedFromImage ? "photo" : "doc.text"
                                    )
                                    Text("·")
                                    Text(incoming.formattedSize)
                                    if incoming.wasConvertedFromImage {
                                        Text("· Converted to PDF")
                                            .foregroundColor(DesignTokens.accent(colorScheme))
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // 2. Smart Existing-File Shortcut if shared from inside the Vault
                    if let existing = incoming.existingVaultItem {
                        Section {
                            Button {
                                openExistingVaultDocument(existing)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(DesignTokens.emerald)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Already in Your Vault")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(.primary)
                                        Text("Tap to open \"\(existing.name)\" directly without creating a duplicate.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text("Open")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(DesignTokens.accent(colorScheme))
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    // 3. Vault Destination Folder Picker
                    if vault.vaultURL == nil {
                        Section("Save Destination") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("No vault folder is connected yet.")
                                    .font(.subheadline.weight(.semibold))
                                Text("Use the local app folder to save & organize imported PDFs immediately, or open the file right away.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Button {
                                    vault.useLocalDocumentsFolder()
                                    selectedFolder = ""
                                    Haptics.light()
                                } label: {
                                    Label("Use \(VaultManager.localFolderDisplayName)", systemImage: "internaldrive")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(.vertical, 4)
                        }
                    } else {
                        Section {
                            // Vault Root option
                            folderRow(
                                title: vault.vaultURL?.lastPathComponent ?? "Documents",
                                subtitle: "Vault Root",
                                path: "",
                                depth: 0,
                                iconName: "books.vertical.fill",
                                iconColor: DesignTokens.accent(colorScheme)
                            )

                            if vault.allFolders.count > 6 {
                                HStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("Filter folders…", text: $folderFilter)
                                        .font(.subheadline)
                                    if !folderFilter.isEmpty {
                                        Button { folderFilter = "" } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 2)
                            }

                            ForEach(filteredFolders) { folder in
                                let depth = folder.relativePath.split(separator: "/").count - 1
                                let parentDir = (folder.relativePath as NSString).deletingLastPathComponent
                                let subText = (parentDir == "." || parentDir == "/" || parentDir.isEmpty)
                                    ? "\(folder.pdfCount) \(folder.pdfCount == 1 ? "doc" : "docs")"
                                    : "\(parentDir) · \(folder.pdfCount) \(folder.pdfCount == 1 ? "doc" : "docs")"

                                folderRow(
                                    title: folder.name,
                                    subtitle: subText,
                                    path: folder.relativePath,
                                    depth: folderFilter.isEmpty ? min(depth, 3) : 0,
                                    iconName: "folder.fill",
                                    iconColor: DesignTokens.skyFolderTop
                                )
                            }
                        } header: {
                            HStack {
                                Text("Save To Folder")
                                Spacer()
                                Button {
                                    newFolderName = ""
                                    showNewFolderAlert = true
                                } label: {
                                    Label("New Folder", systemImage: "folder.badge.plus")
                                        .font(.caption.weight(.semibold))
                                        .textCase(nil)
                                }
                            }
                        }
                    }

                    if !errorMessage.isEmpty {
                        Section {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(DesignTokens.coralRed)
                        }
                    }
                }
                .listStyle(.insetGrouped)

                // Sticky Goodnotes-Style Primary Action Footer
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(DesignTokens.hairline(colorScheme))
                        .frame(height: 0.5)

                    HStack(spacing: 12) {
                        Button {
                            performImportAndOpen()
                        } label: {
                            HStack(spacing: 8) {
                                if isSaving {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "square.and.arrow.down.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(vault.vaultURL != nil ? "Import & Open" : "Open Document")
                                        .font(.system(size: 15.5, weight: .bold))
                                    if vault.vaultURL != nil {
                                        Text("Save to \(destinationDisplayName)")
                                            .font(.system(size: 11.5, weight: .medium))
                                            .opacity(0.88)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(DesignTokens.chromePrimary(colorScheme))
                }
            }
            .navigationTitle("Import to Pencil Ink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        incomingFiles.finishPending(deleteStagedFile: true)
                    }
                    .disabled(isSaving)
                }
            }
            .alert("New Folder", isPresented: $showNewFolderAlert) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    createAndSelectFolder()
                }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            } message: {
                Text(selectedFolder.isEmpty
                     ? "Creates a new folder inside your Vault Root."
                     : "Creates a subfolder inside \"\(destinationDisplayName)\".")
            }
            .onAppear {
                documentTitle = incoming.suggestedTitle
                let saved = incomingFiles.lastImportFolder
                if !saved.isEmpty && vault.allFolders.contains(where: { $0.relativePath == saved }) {
                    selectedFolder = saved
                } else {
                    selectedFolder = ""
                }
            }
        }
    }

    private func folderRow(
        title: String,
        subtitle: String,
        path: String,
        depth: Int,
        iconName: String,
        iconColor: Color
    ) -> some View {
        let isSelected = (selectedFolder == path)
        return Button {
            selectedFolder = path
            Haptics.selection()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 18))
                    .foregroundColor(iconColor)
                    .frame(width: 24)
                    .padding(.leading, CGFloat(depth) * 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundColor(DesignTokens.accent(colorScheme))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func createAndSelectFolder() {
        let clean = newFolderName
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            try vault.createFolder(name: clean, inFolder: selectedFolder)
            let newPath = selectedFolder.isEmpty ? clean : "\(selectedFolder)/\(clean)"
            selectedFolder = newPath
            Haptics.light()
        } catch {
            errorMessage = error.localizedDescription
        }
        newFolderName = ""
    }

    private func openExistingVaultDocument(_ item: PDFItem) {
        Haptics.selection()
        incomingFiles.finishPending(deleteStagedFile: true)
        tabManager.openDocument(
            url: item.url,
            relativePath: item.relativePath,
            title: item.name,
            isHobonichi: item.isHobonichi,
            vault: vault
        )
    }

    private func performImportAndOpen() {
        isSaving = true
        errorMessage = ""

        if vault.vaultURL == nil {
            // Open directly from staged URL if user hasn't picked a vault yet
            let url = incoming.stagedPDFURL
            let title = documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            incomingFiles.finishPending(deleteStagedFile: false)
            tabManager.openDocument(
                url: url,
                relativePath: url.lastPathComponent,
                title: title.isEmpty ? incoming.suggestedTitle : title,
                isHobonichi: false,
                vault: vault
            )
            isSaving = false
            return
        }

        let desiredTitle = documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetFolder = selectedFolder
        do {
            let imported = try vault.importPDFCopy(
                from: incoming.stagedPDFURL,
                intoFolder: targetFolder,
                customTitle: desiredTitle.isEmpty ? incoming.suggestedTitle : desiredTitle
            )
            incomingFiles.lastImportFolder = targetFolder
            syncManager.uploadNewBookToDrive(pdfURL: imported.url, relativePath: imported.relPath)
            let finalName = imported.url.deletingPathExtension().lastPathComponent
            Haptics.success()
            incomingFiles.finishPending(deleteStagedFile: true)
            tabManager.openDocument(
                url: imported.url,
                relativePath: imported.relPath,
                title: finalName,
                isHobonichi: false,
                vault: vault
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
