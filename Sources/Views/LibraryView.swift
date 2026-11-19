import SwiftUI
import UniformTypeIdentifiers

private enum ActivePickerMode {
    case folder
    case openSinglePDF
    case importPDFCopy
}

private enum LibraryTab: String, CaseIterable {
    case documents = "Documents"
    case favorites = "Favorites"
    case journals = "Journals"
}

private enum LibrarySort: String, CaseIterable, Identifiable {
    case modified = "Recently Modified"
    case name = "Title (A–Z)"
    case annotated = "Annotated First"

    var id: String { rawValue }
}

private struct BreadcrumbItem: Identifiable {
    let name: String
    let path: String
    var id: String { path }
}

struct LibraryView: View {
    @EnvironmentObject var vault: VaultManager
    @EnvironmentObject var syncManager: DriveSyncManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var settings: AppSettings

    @State private var activeTab: LibraryTab = .documents
    @State private var sortOption: LibrarySort = .modified
    @State private var currentFolder: String = ""
    @State private var searchText: String = ""

    @State private var showImporter = false
    @State private var pickerMode: ActivePickerMode = .folder
    @State private var showSyncSettings = false
    @State private var showAppSettings = false
    @State private var showNewNotebook = false
    @State private var showNewHobonichi = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingItem: PDFItem? = nil
    @State private var renameText = ""

    private var allowedTypes: [UTType] {
        pickerMode == .folder ? [.folder] : [.pdf]
    }

    private var openTabIDs: Set<String> {
        Set(tabManager.tabs.map { $0.id })
    }

    private var recentItems: [PDFItem] {
        guard activeTab == .documents, currentFolder.isEmpty, searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }
        var out: [PDFItem] = []
        for rel in vault.recentPaths {
            if let item = vault.pdfs.first(where: { $0.relativePath == rel }) {
                out.append(item)
            }
            if out.count >= 6 { break }
        }
        return out
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
        var list: [PDFItem]
        switch activeTab {
        case .favorites:
            list = vault.pdfs.filter { vault.isFavorite($0.relativePath) }
            if !q.isEmpty {
                list = list.filter { $0.name.lowercased().contains(q) || $0.relativeFolder.lowercased().contains(q) }
            }
        case .journals:
            list = vault.pdfs.filter { $0.isHobonichi }
            if !q.isEmpty {
                list = list.filter { $0.name.lowercased().contains(q) }
            }
        case .documents:
            if !q.isEmpty {
                list = vault.pdfs.filter {
                    $0.name.lowercased().contains(q) || $0.relativeFolder.lowercased().contains(q)
                }
            } else {
                list = vault.pdfs.filter { item in
                    let folder = (item.relativeFolder == "." || item.relativeFolder == "/") ? "" : item.relativeFolder
                    if currentFolder.isEmpty && item.isHobonichi { return false }
                    return folder == currentFolder
                }
            }
        }

        switch sortOption {
        case .modified:
            return list.sorted { $0.modifiedAt > $1.modifiedAt }
        case .name:
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .annotated:
            return list.sorted {
                if $0.hasInk != $1.hasInk { return $0.hasInk && !$1.hasInk }
                return $0.modifiedAt > $1.modifiedAt
            }
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
                    // Header Controls: Segmented Tabs + Sort Menu + Breadcrumbs
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Picker("Section", selection: $activeTab) {
                                ForEach(LibraryTab.allCases, id: \.self) { t in
                                    Text(t.rawValue).tag(t)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 330)

                            Spacer()

                            Menu {
                                ForEach(LibrarySort.allCases) { opt in
                                    Button {
                                        sortOption = opt
                                        Haptics.selection()
                                    } label: {
                                        if sortOption == opt {
                                            Label(opt.rawValue, systemImage: "checkmark")
                                        } else {
                                            Text(opt.rawValue)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.up.arrow.down")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(sortOption.rawValue)
                                        .font(.system(size: 12.5, weight: .semibold))
                                }
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(Capsule())
                            }
                        }

                        if activeTab == .documents && !currentFolder.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    Button("Documents") {
                                        withAnimation(.easeOut(duration: 0.2)) { currentFolder = "" }
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.blue)
                                    ForEach(breadcrumbParts) { crumb in
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Button(crumb.name) {
                                            withAnimation(.easeOut(duration: 0.2)) { currentFolder = crumb.path }
                                        }
                                        .font(.subheadline.weight(crumb.path == currentFolder ? .bold : .semibold))
                                        .foregroundColor(crumb.path == currentFolder ? .primary : .blue)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)

                    if visibleFolders.isEmpty && visiblePDFs.isEmpty && recentItems.isEmpty {
                        emptyFolderState
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 26) {
                                // Quick Continue Studying / Recent Books Strip
                                if !recentItems.isEmpty {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("Continue Studying")
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 14) {
                                                ForEach(recentItems) { item in
                                                    RecentBookPill(
                                                        item: item,
                                                        isOpenInTab: openTabIDs.contains(item.id),
                                                        vault: vault
                                                    ) {
                                                        openItem(item)
                                                    }
                                                }
                                            }
                                            .padding(.vertical, 2)
                                        }
                                    }
                                }

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

                                if !visiblePDFs.isEmpty {
                                    VStack(alignment: .leading, spacing: 14) {
                                        Text(sectionTitle)
                                            .font(.headline)
                                            .foregroundColor(.primary)

                                        LazyVGrid(columns: bookColumns, spacing: 24) {
                                            ForEach(visiblePDFs) { item in
                                                BookCoverCard(
                                                    item: item,
                                                    isFavorite: vault.isFavorite(item.relativePath),
                                                    isOpenInTab: openTabIDs.contains(item.id),
                                                    vault: vault,
                                                    onOpen: { openItem(item) },
                                                    onToggleFavorite: {
                                                        vault.toggleFavorite(item.relativePath)
                                                        Haptics.light()
                                                    },
                                                    onRename: {
                                                        renameText = item.name
                                                        renamingItem = item
                                                    },
                                                    onCycleColor: {
                                                        vault.cycleCoverColor(for: item)
                                                        Haptics.selection()
                                                    },
                                                    onDuplicate: {
                                                        try? vault.duplicatePDF(item)
                                                        Haptics.light()
                                                    },
                                                    onDelete: {
                                                        tabManager.handleDeletedDocument(relativePath: item.relativePath)
                                                        try? vault.deletePDF(item)
                                                        Haptics.light()
                                                    }
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 44)
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
            .navigationTitle(navigationHeaderTitle)
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
                        showAppSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
        }
        .sheet(isPresented: $showSyncSettings) {
            DriveSyncSettingsSheet(syncManager: syncManager, vault: vault)
                .preferredColorScheme(settings.appTheme.preferredColorScheme)
        }
        .sheet(isPresented: $showAppSettings) {
            SettingsSheet(onChooseVaultFolder: {
                pickerMode = .folder
                showImporter = true
            })
            .preferredColorScheme(settings.appTheme.preferredColorScheme)
        }
        .sheet(isPresented: $showNewNotebook) {
            NewNotebookSheet(vault: vault, targetFolder: currentFolder) { url, rel in
                tabManager.openDocument(url: url, relativePath: rel, isHobonichi: false, vault: vault)
            }
            .preferredColorScheme(settings.appTheme.preferredColorScheme)
        }
        .sheet(isPresented: $showNewHobonichi) {
            NewHobonichiSheet(vault: vault, targetFolder: activeTab == .journals ? "Journals" : currentFolder) { url, rel in
                tabManager.openDocument(url: url, relativePath: rel, isHobonichi: true, vault: vault)
            }
            .preferredColorScheme(settings.appTheme.preferredColorScheme)
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
                if let item = renamingItem,
                   let renamed = try? vault.renamePDF(item, newTitle: renameText) {
                    tabManager.handleRenamedDocument(
                        oldRelativePath: item.relativePath,
                        newURL: renamed.url,
                        newRelativePath: renamed.relPath,
                        newTitle: renamed.title
                    )
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
                        let scoped = url.startAccessingSecurityScopedResource()
                        let rel = vault.relativePath(for: url)
                        tabManager.openDocument(
                            url: url,
                            relativePath: rel,
                            isHobonichi: false,
                            isStandaloneScoped: scoped,
                            vault: vault
                        )
                    case .importPDFCopy:
                        if let imported = try? vault.importPDFCopy(from: url, intoFolder: currentFolder) {
                            tabManager.openDocument(
                                url: imported.url,
                                relativePath: imported.relPath,
                                isHobonichi: false,
                                vault: vault
                            )
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

    private var navigationHeaderTitle: String {
        if activeTab == .documents && !currentFolder.isEmpty {
            return (currentFolder as NSString).lastPathComponent
        }
        return "Pencil Ink"
    }

    private var sectionTitle: String {
        switch activeTab {
        case .favorites: return "Favorites (\(visiblePDFs.count))"
        case .journals: return "Hobonichi Weeks Journals (\(visiblePDFs.count))"
        case .documents: return "Documents (\(visiblePDFs.count))"
        }
    }

    private func openItem(_ item: PDFItem) {
        tabManager.openDocument(
            url: item.url,
            relativePath: item.relativePath,
            title: item.name,
            isHobonichi: item.isHobonichi,
            vault: vault
        )
    }

    private func folderCard(_ folder: FolderItem) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                currentFolder = folder.relativePath
            }
            Haptics.selection()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.blue.opacity(0.16))
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
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private var emptyFolderState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: activeTab == .favorites ? "star" : (activeTab == .journals ? "calendar" : "books.vertical"))
                .font(.system(size: 46))
                .foregroundColor(.blue.opacity(0.8))
            Text(activeTab == .favorites ? "No Favorite Documents" : (activeTab == .journals ? "No Hobonichi Journals Yet" : "No Documents Here"))
                .font(.headline)
            Text(activeTab == .favorites
                 ? "Tap ••• on any notebook or textbook and choose Add to Favorites to pin it here."
                 : (activeTab == .journals
                    ? "Create an ever-expanding Hobonichi Techo Weeks journal with monthly grids, weekly spreads, and back notes."
                    : "Tap + New above to create a notebook, Hobonichi journal, or import a PDF."))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if activeTab != .favorites {
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
            }
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

private struct RecentBookPill: View {
    let item: PDFItem
    let isOpenInTab: Bool
    @ObservedObject var vault: VaultManager
    let onOpen: () -> Void

    private var palette: CoverPalette {
        HobonichiEngine.palette(for: item.name, customID: vault.coverColors[item.relativePath])
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(palette.bgColor))
                    .frame(width: 30, height: 38)
                    .overlay(
                        Image(systemName: item.isHobonichi ? "calendar" : "doc.richtext")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if !item.relativeFolder.isEmpty {
                            Text(item.relativeFolder)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        if isOpenInTab {
                            Text("· Open")
                                .font(.caption2.bold())
                                .foregroundColor(.blue)
                        }
                    }
                }
                .frame(maxWidth: 175, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isOpenInTab ? Color.blue.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct BookCoverCard: View {
    let item: PDFItem
    let isFavorite: Bool
    let isOpenInTab: Bool
    @ObservedObject var vault: VaultManager
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
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
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(palette.bgColor))

                    if let img = thumb {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
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
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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

                    // Top-right status badges (Favorite / Annotated / Open Tab)
                    VStack {
                        HStack(spacing: 4) {
                            Spacer()
                            if isOpenInTab {
                                Text("OPEN")
                                    .font(.system(size: 8.5, weight: .heavy))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.blue)
                                    .clipShape(Capsule())
                            }
                            if isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.yellow)
                                    .padding(4)
                                    .background(Circle().fill(Color.black.opacity(0.55)))
                            }
                            if item.hasInk {
                                Image(systemName: "pencil.tip.crop.circle.fill")
                                    .font(.system(size: 17))
                                    .foregroundColor(.blue)
                                    .background(Circle().fill(Color.white).padding(2))
                            }
                        }
                        .padding(7)
                        Spacer()
                    }
                }
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(
                            isOpenInTab
                                ? Color.blue.opacity(0.75)
                                : (item.isHobonichi ? Color.yellow.opacity(0.42) : Color.primary.opacity(0.12)),
                            lineWidth: isOpenInTab ? 2 : 1
                        )
                )
                .shadow(color: .black.opacity(0.30), radius: 8, y: 4)
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
                    Button { onOpen() } label: { Label("Open in Tab", systemImage: "book.open") }
                    Button { onToggleFavorite() } label: {
                        Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star")
                    }
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
