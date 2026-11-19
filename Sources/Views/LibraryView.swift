import SwiftUI
import UniformTypeIdentifiers

private enum ActivePickerMode {
    case folder
    case pdf
}

struct LibraryView: View {
    @EnvironmentObject var vault: VaultManager
    @EnvironmentObject var syncManager: DriveSyncManager
    @State private var showImporter = false
    @State private var showSyncSettings = false
    @State private var pickerMode: ActivePickerMode = .folder
    @State private var searchText = ""
    @State private var openedPDF: URL?
    @State private var openedRelativePath: String = ""
    @State private var standaloneScopedURL: URL?

    private var filteredPDFs: [PDFItem] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return vault.pdfs
        }
        let q = searchText.lowercased()
        return vault.pdfs.filter {
            $0.name.lowercased().contains(q) || $0.relativeFolder.lowercased().contains(q)
        }
    }

    private var allowedTypes: [UTType] {
        pickerMode == .folder ? [.folder] : [.pdf]
    }

    private func relativeVaultPath(for url: URL) -> String {
        if let rootPath = vault.vaultURL?.path, url.path.hasPrefix(rootPath) {
            return String(url.path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    var body: some View {
        Group {
            if let pdf = openedPDF {
                NotebookScreen(
                    pdfURL: pdf,
                    relativePath: openedRelativePath,
                    onClose: {
                        if let single = standaloneScopedURL, single == pdf {
                            single.stopAccessingSecurityScopedResource()
                            standaloneScopedURL = nil
                        }
                        openedPDF = nil
                        openedRelativePath = ""
                        vault.refreshPDFList()
                    }
                )
            } else {
                libraryHome
            }
        }
        .sheet(isPresented: $showSyncSettings) {
            DriveSyncSettingsSheet(syncManager: syncManager, vault: vault)
                .preferredColorScheme(.dark)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                DispatchQueue.main.async {
                    if pickerMode == .folder {
                        vault.setVaultFolder(url)
                    } else {
                        if url.startAccessingSecurityScopedResource() {
                            standaloneScopedURL = url
                        }
                        openedRelativePath = relativeVaultPath(for: url)
                        openedPDF = url
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    vault.statusMessage = "File picker error: \(error.localizedDescription)"
                }
            }
        }
    }

    private var libraryHome: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !vault.statusMessage.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.orange)
                        Text(vault.statusMessage)
                            .font(.caption)
                            .foregroundColor(.primary)
                        Spacer()
                        Button {
                            vault.statusMessage = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.14))
                }

                if vault.vaultURL == nil {
                    emptyVaultView
                } else if filteredPDFs.isEmpty {
                    VStack(spacing: 14) {
                        Spacer()
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 46))
                            .foregroundColor(.secondary)
                        Text(vault.pdfs.isEmpty ? "No PDFs found in this folder" : "No matching PDFs")
                            .font(.headline)
                        Text(vault.vaultURL?.lastPathComponent ?? "")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if vault.isUsingLocalFallback {
                            Text("Drop PDFs into On My iPad → Pencil Ink in the Files app, then pull down to refresh.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 36)
                        }
                        Button("Refresh") {
                            vault.refreshPDFList()
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                } else {
                    List(filteredPDFs) { item in
                        Button {
                            openedRelativePath = relativeVaultPath(for: item.url)
                            openedPDF = item.url
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.blue.opacity(0.18))
                                        .frame(width: 42, height: 52)
                                    Image(systemName: item.hasInk ? "pencil.and.outline" : "doc.richtext")
                                        .font(.system(size: 19, weight: .semibold))
                                        .foregroundColor(.blue)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                    HStack(spacing: 6) {
                                        if !item.relativeFolder.isEmpty {
                                            Text(item.relativeFolder)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        if item.hasInk {
                                            Text("· Annotated")
                                                .font(.caption.weight(.semibold))
                                                .foregroundColor(.green)
                                        }
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        vault.refreshPDFList()
                        if syncManager.config.isConnected {
                            await syncManager.syncAllAnnotatedBooks(vault: vault)
                        }
                    }
                }
            }
            .navigationTitle("Pencil Ink")
            .searchable(text: $searchText, prompt: "Search PDFs in vault")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SyncStatusDotButton(syncManager: syncManager) {
                        showSyncSettings = true
                    }
                    Button {
                        pickerMode = .pdf
                        showImporter = true
                    } label: {
                        Label("Open PDF", systemImage: "doc.badge.plus")
                    }
                    Button {
                        pickerMode = .folder
                        showImporter = true
                    } label: {
                        Label("Vault Folder", systemImage: "folder.badge.gearshape")
                    }
                }
            }
        }
    }

    private var emptyVaultView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 56))
                .foregroundColor(.blue)
            Text("Connect Your Obsidian Vault")
                .font(.title2.bold())
            Text("Pick your Obsidian vault folder once. Pencil Ink opens your PDFs in-place and syncs strokes directly with Obsidian & Google Drive.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button {
                pickerMode = .folder
                showImporter = true
            } label: {
                Text("Choose Vault Folder")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Button("Or Open a Single PDF") {
                pickerMode = .pdf
                showImporter = true
            }
            .font(.subheadline)
            Button("Use Local App Folder (On My iPad → Pencil Ink)") {
                vault.useLocalDocumentsFolder()
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.top, 4)
            Spacer()
        }
    }
}
