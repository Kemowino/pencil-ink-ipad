import SwiftUI
import UniformTypeIdentifiers

private enum ActivePickerMode {
    case folder
    case openSinglePDF
    case importPDFCopy
}

private enum LibraryTab: String, CaseIterable {
    case documents = "Documents"
    case journals = "Journals"
}

private struct BreadcrumbItem: Identifiable {
    let name: String
    let path: String
    var id: String { path }
}

struct LibraryView: View {
    @EnvironmentObject var vault: VaultManager
    @EnvironmentObject var syncManager: DriveSyncManager

    @State private var activeTab: LibraryTab = .documents
    @State private var currentFolder: String = ""
    @State private var searchText: String = ""

    @State private var showImporter = false
    @State private var pickerMode: ActivePickerMode = .folder
    @State private var showSyncSettings = false
    @State private var showNewNotebook = false
    @State private var showNewHobonichi = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingItem: PDFItem? = nil
    @State private var renameText = ""

    @State private var openedPDF: URL?
    @State private var openedRelativePath: String = ""
    @State private var standaloneScopedURL: URL?

    private var allowedTypes: [UTType] {
        pickerMode == .folder ? [.folder] : [.pdf]
    }

    private var visibleFolders: [FolderItem] {
        guard activeTab == .documents else { return [] }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            return vault.allFolders.filter { $0.name.lowercased().contains(q) }
        }
        return vault.allFolders.filter { folder in
            let parent = (folder.relativePath as NSString).deletingLastPathComponent
            let normParent = (parent == "." || parent == "/") ? "" : parent
            if currentFolder.isEmpty && folder.relativePath == "Journals" { return false }
            return normParent == currentFolder
        }
    }

    private var visiblePDFs: [PDFItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if activeTab == .journals {
            let journals = vault.pdfs.filter { $0.isHobonichi }
            if q.isEmpty { return journals }
            return journals.filter { $0.name.lowercased().contains(q) }
        }
        if !q.isEmpty {
            return vault.pdfs.filter {
                $0.name.lowercased().contains(q) || $0.relativeFolder.lowercased().contains(q)
            }
        }
        return vault.pdfs.filter { item in
            let folder = (item.relativeFolder == "." || item.relativeFolder == "/") ? "" : item.relativeFolder
            if currentFolder.isEmpty && item.isHobonichi { return false }
            return folder == currentFolder
        }
    }

    private var breadcrumbParts: [BreadcrumbItem] {
        if currentFolder.isEmpty { return [] }
        let parts = currentFolder.split(separator: "/").map(String.init)
        var acc = ""
        return parts.map { seg in
            acc = acc.isEmpty ? seg : "\(acc)/\(seg)"
            return BreadcrumbItem(name: seg, path: acc)
        }
    }

    private let folderColumns = [GridItem(.adaptive(minimum: 195, maximum: 280), spacing: 14)]
    private let bookColumns = [GridItem(.adaptive(minimum: 155, maximum: 210), spacing: 20)]

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
        .sheet(isPresented: $showNewNotebook) {
            NewNotebookSheet(vault: vault, targetFolder: currentFolder) { url, rel in
                openedRelativePath = rel
                openedPDF = url
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showNewHobonichi) {
            NewHobonichiSheet(vault: vault, targetFolder: activeTab == .journals ? "Journals" : currentFolder) { url, rel in
                openedRelativePath = rel
                openedPDF = url
            }
            .preferredColorScheme(.dark)
        }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                try? vault.createFolder(name: newFolderName, inFolder: currentFolder)
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename Document", isPresented: Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )) {
            TextField("New title", text: $renameText)
            Button("Rename") {
                if let item = renamingItem {
                    try? vault.renamePDF(item, newTitle: renameText)
                }
                renamingItem = nil
            }
            Button("Cancel", role: .cancel) { renamingItem = nil }
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
                    switch pickerMode {
                    case .folder:
                        currentFolder = ""
                        vault.setVaultFolder(url)
                    case .openSinglePDF:
                        if url.startAccessingSecurityScopedResource() {
                            standaloneScopedURL = url
                        }
                        openedRelativePath = vault.relativePath(for: url)
                        openedPDF = url
                    case .importPDFCopy:
                        if let imported = try? vault.importPDFCopy(from: url, intoFolder: currentFolder) {
                            openedRelativePath = imported.relPath
                            openedPDF = imported.url
                        }
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
                        Image(systemName: "info.circle.fill").foregroundColor(.orange)
                        Text(vault.statusMessage).font(.caption)
                        Spacer()
                        Button { vault.statusMessage = "" } label: {
                            Image(systemName: "xmark").font(.caption.bold()).foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.14))
                }

                if vault.vaultURL == nil {
                    emptyVaultView
                } else {
                    // Segmented Tabs (Documents / Journals) + Breadcrumbs
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("Section", selection: $activeTab) {
                                ForEach(LibraryTab.allCases, id: \.self) { t in
                                    Text(t.rawValue).tag(t)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 260)
                            Spacer()
                        }

                        if activeTab == .documents && !currentFolder.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    Button("Documents") { currentFolder = "" }
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.blue)
                                    ForEach(breadcrumbParts) { crumb in
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Button(crumb.name) { currentFolder = crumb.path }
                                            .font(.subheadline.weight(crumb.path == currentFolder ? .bold : .semibold))
                                            .foregroundColor(crumb.path == currentFolder ? .primary : .blue)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)

                    if visibleFolders.isEmpty && visiblePDFs.isEmpty {
                        emptyFolderState
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 26) {
                                if !visibleFolders.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Folders (\(visibleFolders.count))")
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        LazyVGrid(columns: folderColumns, spacing: 14) {
                                            ForEach(visibleFolders) { folder in
                                                folderCard(folder)
                                            }
                                        }
                                    }
                                }

                                VStack(alignment: .leading, spacing: 14) {
                                    Text(activeTab == .journals
                                         ? "Hobonichi Weeks Journals (\(visiblePDFs.count))"
                                         : "Documents (\(visiblePDFs.count))")
                                        .font(.headline)
                                        .foregroundColor(.primary)

                                    LazyVGrid(columns: bookColumns, spacing: 24) {
                                        ForEach(visiblePDFs) { item in
                                            BookCoverCard(
                                                item: item,
                                                vault: vault,
                                                onOpen: {
                                                    openedRelativePath = item.relativePath
                                                    openedPDF = item.url
                                                },
                                                onRename: {
                                                    renameText = item.name
                                                    renamingItem = item
                                                },
                                                onCycleColor: {
                                                    vault.cycleCoverColor(for: item)
                                                },
                                                onDuplicate: {
                                                    try? vault.duplicatePDF(item)
                                                },
                                                onDelete: {
                                                    try? vault.deletePDF(item)
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 40)
                        }
                        .refreshable {
                            vault.refreshPDFList()
                            if syncManager.config.isConnected {
                                await syncManager.syncAllAnnotatedBooks(vault: vault)
                            }
                        }
                    }
                }
            }
            .navigationTitle(currentFolder.isEmpty || activeTab == .journals ? "Pencil Ink" : (currentFolder as NSString).lastPathComponent)
            .searchable(text: $searchText, prompt: "Search notebooks & folders")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SyncStatusDotButton(syncManager: syncManager) {
                        showSyncSettings = true
                    }

                    if vault.vaultURL != nil {
                        Menu {
                            Button {
                                showNewNotebook = true
                            } label: {
                                Label("New Notebook…", systemImage: "book.closed")
                            }
                            Button {
                                showNewHobonichi = true
                            } label: {
                                Label("New Hobonichi Journal…", systemImage: "calendar")
                            }
                            Divider()
                            Button {
                                pickerMode = .importPDFCopy
                                showImporter = true
                            } label: {
                                Label("Import PDF into Folder…", systemImage: "square.and.arrow.down")
                            }
                            Button {
                                pickerMode = .openSinglePDF
                                showImporter = true
                            } label: {
                                Label("Open Single PDF In-Place…", systemImage: "doc")
                            }
                            Divider()
                            Button {
                                newFolderName = ""
                                showNewFolderAlert = true
                            } label: {
                                Label("New Folder…", systemImage: "folder.badge.plus")
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("New")
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .clipShape(Capsule())
                        }
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

    private func folderCard(_ folder: FolderItem) -> some View {
        Button {
            currentFolder = folder.relativePath
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.18))
                        .frame(width: 40, height: 40)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 19))
                        .foregroundColor(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(folder.pdfCount) \(folder.pdfCount == 1 ? "document" : "documents")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var emptyFolderState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: activeTab == .journals ? "calendar" : "books.vertical")
                .font(.system(size: 46))
                .foregroundColor(.blue.opacity(0.8))
            Text(activeTab == .journals ? "No Hobonichi Journals Yet" : "No Documents Here")
                .font(.headline)
            Text(activeTab == .journals
                 ? "Create an ever-expanding Hobonichi Techo Weeks journal with monthly grids, weekly spreads, and back notes."
                 : "Tap + New above to create a notebook, Hobonichi journal, or import a PDF.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            HStack(spacing: 12) {
                if activeTab == .journals {
                    Button("New Hobonichi Journal") { showNewHobonichi = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("New Notebook") { showNewNotebook = true }
                        .buttonStyle(.borderedProminent)
                    Button("New Hobonichi") { showNewHobonichi = true }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.top, 4)
            Spacer()
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
                pickerMode = .openSinglePDF
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

private struct BookCoverCard: View {
    let item: PDFItem
    @ObservedObject var vault: VaultManager
    let onOpen: () -> Void
    let onRename: () -> Void
    let onCycleColor: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var thumb: UIImage? = nil

    private var palette: CoverPalette {
        HobonichiEngine.palette(for: item.name, customID: vault.coverColors[item.relativePath])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(palette.bgColor))

                    if let img = thumb {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        // Authentic Goodnotes / Hobonichi Notebook Cover Plaque
                        VStack {
                            VStack(spacing: 5) {
                                if item.isHobonichi {
                                    Text("HOBONICHI WEEKS")
                                        .font(.system(size: 8.5, weight: .heavy))
                                        .tracking(1.0)
                                        .foregroundColor(Color(red: 0.61, green: 0.49, blue: 0.33))
                                }
                                Text(item.name)
                                    .font(.system(size: 12.5, weight: .bold))
                                    .foregroundColor(Color(white: 0.12))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(3)
                                Capsule()
                                    .fill(Color.black.opacity(0.15))
                                    .frame(width: 44, height: 2)
                            }
                            .padding(.vertical, 11)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.93))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                            Spacer()
                        }
                        .padding(.top, 22)
                        .padding(.leading, 24)
                        .padding(.trailing, 14)
                    }

                    // Realistic Book Spine Gradient
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.28),
                            Color.white.opacity(0.14),
                            Color.black.opacity(0.08),
                            Color.black.opacity(0.32),
                            Color.white.opacity(0.10)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 15)

                    // Annotated badge
                    if item.hasInk {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "pencil.tip.crop.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.blue)
                                    .background(Circle().fill(Color.white).padding(2))
                                    .padding(7)
                            }
                            Spacer()
                        }
                    }
                }
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(item.isHobonichi ? Color.yellow.opacity(0.42) : Color.white.opacity(0.12), lineWidth: 1.2)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Text(item.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 2)
                Menu {
                    Button { onOpen() } label: { Label("Open", systemImage: "book.open") }
                    Button { onCycleColor() } label: { Label("Change Cover Color", systemImage: "paintpalette") }
                    Button { onRename() } label: { Label("Rename…", systemImage: "pencil") }
                    Button { onDuplicate() } label: { Label("Duplicate", systemImage: "doc.on.doc") }
                    Divider()
                    Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 26)
                }
            }
        }
        .onAppear {
            if thumb == nil {
                if let cached = vault.cachedCoverThumb(for: item) {
                    thumb = cached
                } else {
                    vault.loadCoverThumb(for: item) { img in
                        thumb = img
                    }
                }
            }
        }
    }
}
