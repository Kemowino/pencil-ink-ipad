import SwiftUI
import UniformTypeIdentifiers

private enum ActivePickerMode {
    case folder
    case openSinglePDF
    case importPDFCopy
}

private enum LibrarySection: String, CaseIterable {
    case documents = "Documents"
    case journals = "Journals"
}

private enum LibrarySort: String, CaseIterable, Identifiable {
    case modified = "Date"
    case name = "Name"
    case annotated = "Annotated"

    var id: String { rawValue }
}

private enum LibraryDisplayMode: String {
    case grid
    case list
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
    @Environment(\.colorScheme) private var colorScheme

    @State private var activeSection: LibrarySection = .documents
    @State private var sortOption: LibrarySort = .modified
    @State private var displayMode: LibraryDisplayMode = .grid
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

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleFolders: [FolderItem] {
        guard activeSection == .documents else { return [] }
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
        let filtered: [PDFItem]
        if activeSection == .journals {
            let journals = vault.pdfs.filter { $0.isHobonichi }
            if q.isEmpty {
                filtered = journals
            } else {
                filtered = journals.filter { $0.name.lowercased().contains(q) }
            }
        } else if !q.isEmpty {
            filtered = vault.pdfs.filter {
                $0.name.lowercased().contains(q) || $0.relativeFolder.lowercased().contains(q)
            }
        } else {
            filtered = vault.pdfs.filter { item in
                let folder = (item.relativeFolder == "." || item.relativeFolder == "/") ? "" : item.relativeFolder
                if currentFolder.isEmpty && item.isHobonichi { return false }
                return folder == currentFolder
            }
        }

        switch sortOption {
        case .modified:
            return filtered.sorted { $0.modifiedAt > $1.modifiedAt }
        case .name:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .annotated:
            return filtered.sorted {
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

    private var pageBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.108, blue: 0.120)
            : Color(red: 0.965, green: 0.968, blue: 0.978)
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 158, maximum: 196), spacing: 26, alignment: .top)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                pageBackground.ignoresSafeArea()

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
                        // Clean Goodnotes Sub-Header: Documents | Journals switcher + Sort & View Toggle
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Picker("Section", selection: Binding(
                                    get: { activeSection },
                                    set: { next in
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                            activeSection = next
                                        }
                                        Haptics.selection()
                                    }
                                )) {
                                    ForEach(LibrarySection.allCases, id: \.self) { sec in
                                        Text(sec.rawValue).tag(sec)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 240)

                                Spacer()

                                Menu {
                                    ForEach(LibrarySort.allCases) { opt in
                                        Button {
                                            sortOption = opt
                                            Haptics.selection()
                                        } label: {
                                            if sortOption == opt {
                                                Label("Sort by \(opt.rawValue)", systemImage: "checkmark")
                                            } else {
                                                Text("Sort by \(opt.rawValue)")
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(sortOption.rawValue)
                                            .font(.system(size: 13, weight: .medium))
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.primary.opacity(0.05))
                                    .clipShape(Capsule())
                                }

                                Button {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        displayMode = (displayMode == .grid) ? .list : .grid
                                    }
                                    Haptics.selection()
                                } label: {
                                    Image(systemName: displayMode == .grid ? "list.bullet" : "square.grid.2x2")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .frame(width: 30, height: 30)
                                        .background(Color.primary.opacity(0.05))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }

                            if activeSection == .documents && !currentFolder.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 5) {
                                        Button {
                                            withAnimation(.easeOut(duration: 0.18)) { currentFolder = "" }
                                            Haptics.selection()
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "chevron.left")
                                                    .font(.system(size: 12, weight: .semibold))
                                                Text("Documents")
                                            }
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.accentColor)
                                        }
                                        .buttonStyle(.plain)

                                        ForEach(breadcrumbParts) { crumb in
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.secondary.opacity(0.7))
                                            Button(crumb.name) {
                                                withAnimation(.easeOut(duration: 0.18)) { currentFolder = crumb.path }
                                                Haptics.selection()
                                            }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 14, weight: crumb.path == currentFolder ? .semibold : .regular))
                                            .foregroundColor(crumb.path == currentFolder ? .primary : .accentColor)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                        .padding(.bottom, 10)

                        // Smooth animated transition between Documents and Journals
                        ZStack {
                            if activeSection == .documents {
                                Group {
                                    if displayMode == .grid {
                                        goodnotesGridView
                                    } else {
                                        goodnotesListView
                                    }
                                }
                                .transition(.asymmetric(
                                    insertion: .move(edge: .leading).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            } else {
                                Group {
                                    if displayMode == .grid {
                                        goodnotesGridView
                                    } else {
                                        goodnotesListView
                                    }
                                }
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            }
                        }
                        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: activeSection)
                    }
                }
            }
            .navigationTitle(navigationHeaderTitle)
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: activeSection == .journals ? "Search journals" : "Search documents & folders")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SyncStatusDotButton(syncManager: syncManager) {
                        showSyncSettings = true
                    }

                    Button {
                        showAppSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundColor(.primary.opacity(0.82))
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
            NewHobonichiSheet(vault: vault, targetFolder: activeSection == .journals ? "Journals" : currentFolder) { url, rel in
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
                if let item = renamingItem {
                    do {
                        if let renamed = try vault.renamePDF(item, newTitle: renameText) {
                            tabManager.handleRenamedDocument(
                                oldRelativePath: item.relativePath,
                                newURL: renamed.url,
                                newRelativePath: renamed.relPath,
                                newTitle: renamed.title
                            )
                            let oldRel = item.relativePath
                            let newRel = renamed.relPath
                            Task {
                                await syncManager.renameBookOnDrive(oldRelativePath: oldRel, newRelativePath: newRel)
                            }
                        }
                    } catch {
                        vault.statusMessage = error.localizedDescription
                    }
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
        if activeSection == .journals {
            return "Journals"
        }
        return currentFolder.isEmpty ? "Documents" : (currentFolder as NSString).lastPathComponent
    }

    // MARK: - Goodnotes Unified Grid View

    private var goodnotesGridView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 28) {
                if !isSearching {
                    if activeSection == .journals {
                        goodnotesNewJournalTile
                    } else {
                        goodnotesNewTile
                    }
                }

                ForEach(visibleFolders) { folder in
                    GoodnotesFolderTile(folder: folder) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            currentFolder = folder.relativePath
                        }
                        Haptics.selection()
                    }
                }

                ForEach(visiblePDFs) { item in
                    GoodnotesDocumentTile(
                        item: item,
                        vault: vault,
                        onOpen: { openItem(item) },
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
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 48)
        }
        .refreshable {
            vault.refreshPDFList()
            if syncManager.config.isConnected {
                await syncManager.syncAllAnnotatedBooks(vault: vault)
            }
        }
    }

    // MARK: - Goodnotes Clean List View

    private var goodnotesListView: some View {
        List {
            if !isSearching {
                Section {
                    if activeSection == .journals {
                        Button {
                            showNewHobonichi = true
                        } label: {
                            Label("New Hobonichi Journal…", systemImage: "plus.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.orange)
                        }
                    } else {
                        Menu {
                            newCreationMenuItems
                        } label: {
                            Label("New Notebook, Folder, or Import…", systemImage: "plus.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }

            if !visibleFolders.isEmpty {
                Section("Folders") {
                    ForEach(visibleFolders) { folder in
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                currentFolder = folder.relativePath
                            }
                            Haptics.selection()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(Color(red: 0.27, green: 0.65, blue: 0.96))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text("\(folder.pdfCount) \(folder.pdfCount == 1 ? "document" : "documents")")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }

            Section(activeSection == .journals ? "Hobonichi Journals" : "Documents") {
                ForEach(visiblePDFs) { item in
                    HStack(spacing: 12) {
                        Button {
                            openItem(item)
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color(HobonichiEngine.palette(for: item.name, customID: vault.coverColors[item.relativePath]).bgColor))
                                    .frame(width: 32, height: 42)
                                    .overlay(
                                        Image(systemName: item.isHobonichi ? "calendar" : "doc.text")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.9))
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        if item.hasInk {
                                            Text("· Annotated")
                                                .font(.caption.weight(.medium))
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)

                        Menu {
                            Button { openItem(item) } label: { Label("Open", systemImage: "book.open") }
                            Button { vault.cycleCoverColor(for: item) } label: { Label("Change Cover Color", systemImage: "paintpalette") }
                            Button { renameText = item.name; renamingItem = item } label: { Label("Rename…", systemImage: "pencil") }
                            Button { try? vault.duplicatePDF(item) } label: { Label("Duplicate", systemImage: "doc.on.doc") }
                            Divider()
                            Button(role: .destructive) {
                                tabManager.handleDeletedDocument(relativePath: item.relativePath)
                                try? vault.deletePDF(item)
                            } label: { Label("Delete", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable {
            vault.refreshPDFList()
            if syncManager.config.isConnected {
                await syncManager.syncAllAnnotatedBooks(vault: vault)
            }
        }
    }

    // MARK: - Iconic Goodnotes Dashed "+ New..." & "+ New Journal..." Tiles

    private var goodnotesNewTile: some View {
        Menu {
            newCreationMenuItems
        } label: {
            VStack(spacing: 10) {
                Color.clear
                    .frame(height: 176)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(
                                Color.accentColor.opacity(0.65),
                                style: StrokeStyle(lineWidth: 1.6, dash: [6, 5])
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.06 : 0.035))
                            )
                            .overlay(
                                VStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 30, weight: .light))
                                        .foregroundColor(.accentColor)
                                    Text("New...")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.accentColor)
                                }
                            )
                            .aspectRatio(0.74, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 176)
                    }

                Text(" ")
                    .font(.system(size: 13.5, weight: .medium))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var goodnotesNewJournalTile: some View {
        Button {
            showNewHobonichi = true
        } label: {
            VStack(spacing: 10) {
                Color.clear
                    .frame(height: 176)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(
                                Color.orange.opacity(0.72),
                                style: StrokeStyle(lineWidth: 1.6, dash: [6, 5])
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.orange.opacity(colorScheme == .dark ? 0.07 : 0.04))
                            )
                            .overlay(
                                VStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 30, weight: .light))
                                        .foregroundColor(.orange)
                                    Text("New Journal...")
                                        .font(.system(size: 13.5, weight: .medium))
                                        .foregroundColor(.orange)
                                }
                            )
                            .aspectRatio(0.74, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 176)
                    }

                Text(" ")
                    .font(.system(size: 13.5, weight: .medium))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var newCreationMenuItems: some View {
        Button {
            showNewNotebook = true
        } label: {
            Label("Notebook", systemImage: "book.closed")
        }
        Button {
            showNewHobonichi = true
        } label: {
            Label("Hobonichi Journal", systemImage: "calendar")
        }
        Button {
            newFolderName = ""
            showNewFolderAlert = true
        } label: {
            Label("Folder", systemImage: "folder.badge.plus")
        }
        Divider()
        Button {
            pickerMode = .importPDFCopy
            showImporter = true
        } label: {
            Label("Import PDF…", systemImage: "square.and.arrow.down")
        }
        Button {
            pickerMode = .openSinglePDF
            showImporter = true
        } label: {
            Label("Open PDF In-Place…", systemImage: "doc")
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

    private var emptyVaultView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
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

// MARK: - Authentic Goodnotes Sky-Blue Folder Tile

private struct GoodnotesFolderTile: View {
    let folder: FolderItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 10) {
                Color.clear
                    .frame(height: 176)
                    .overlay(alignment: .bottom) {
                        GoodnotesFolderArtwork(count: folder.pdfCount)
                            .frame(maxWidth: 148, maxHeight: 122)
                            .padding(.bottom, 6)
                    }

                VStack(spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("\(folder.pdfCount) \(folder.pdfCount == 1 ? "item" : "items")")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct GoodnotesFolderArtwork: View {
    let count: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Path { p in
                    let r: CGFloat = 10
                    let tabW = w * 0.42
                    let tabH = h * 0.16
                    p.move(to: CGPoint(x: 0, y: r))
                    p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: tabW - r, y: 0))
                    p.addQuadCurve(to: CGPoint(x: tabW + 8, y: tabH), control: CGPoint(x: tabW + 2, y: 0))
                    p.addLine(to: CGPoint(x: w - r, y: tabH))
                    p.addQuadCurve(to: CGPoint(x: w, y: tabH + r), control: CGPoint(x: w, y: tabH))
                    p.addLine(to: CGPoint(x: w, y: h - r))
                    p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: r, y: h))
                    p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.25, green: 0.62, blue: 0.94),
                            Color(red: 0.19, green: 0.53, blue: 0.87)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                if count > 0 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.88))
                        .frame(width: w * 0.86, height: h * 0.72)
                        .offset(y: -h * 0.13)
                }

                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.36, green: 0.73, blue: 0.99),
                                Color(red: 0.22, green: 0.59, blue: 0.93)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: w, height: h * 0.78)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.white.opacity(0.24), lineWidth: 0.8)
                    )
            }
            .shadow(color: Color.black.opacity(0.22), radius: 7, y: 4)
        }
    }
}

// MARK: - Goodnotes Document Tile (Landscape & Portrait — Strictly Bounded, Zero Overlap!)

private struct GoodnotesDocumentTile: View {
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
        VStack(spacing: 10) {
            Button(action: onOpen) {
                GeometryReader { geo in
                    let maxW = max(40, geo.size.width)
                    let maxH = max(40, geo.size.height)

                    ZStack(alignment: .bottom) {
                        Color.clear
                        if let img = thumb {
                            let ratio = max(0.55, min(1.85, img.size.width / max(1, img.size.height)))
                            let size = fittedSize(aspect: ratio, maxW: maxW, maxH: maxH)
                            let isLandscape = ratio > 1.08

                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: size.width, height: size.height)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: isLandscape ? 7 : 9, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: isLandscape ? 7 : 9, style: .continuous)
                                            .stroke(Color.black.opacity(0.10), lineWidth: 0.7)
                                    )
                                    .shadow(color: Color.black.opacity(0.22), radius: 7, y: 4)

                                if item.hasInk {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 9, height: 9)
                                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                                        .padding(6)
                                }
                            }
                        } else {
                            let ratio: CGFloat = 0.74
                            let size = fittedSize(aspect: ratio, maxW: maxW, maxH: maxH)

                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color(palette.bgColor))

                                VStack {
                                    VStack(spacing: 4) {
                                        if item.isHobonichi {
                                            Text("HOBONICHI")
                                                .font(.system(size: 7.5, weight: .heavy))
                                                .tracking(1.1)
                                                .foregroundColor(Color(red: 0.61, green: 0.49, blue: 0.33))
                                        }
                                        Text(item.name)
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundColor(Color(white: 0.14))
                                            .multilineTextAlignment(.center)
                                            .lineLimit(3)
                                    }
                                    .padding(.vertical, 9)
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.white.opacity(0.94))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    Spacer()
                                }
                                .padding(.top, 20)
                                .padding(.leading, 20)
                                .padding(.trailing, 12)

                                LinearGradient(
                                    colors: [
                                        Color.black.opacity(0.26),
                                        Color.white.opacity(0.14),
                                        Color.black.opacity(0.22),
                                        Color.clear
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 13)
                            }
                            .frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.white.opacity(0.14), lineWidth: 0.7)
                            )
                            .shadow(color: Color.black.opacity(0.24), radius: 7, y: 4)
                        }
                    }
                    .frame(width: maxW, height: maxH, alignment: .bottom)
                }
                .frame(height: 176)
                .clipped()
            }
            .buttonStyle(.plain)

            VStack(spacing: 2) {
                Menu {
                    Button { onOpen() } label: { Label("Open", systemImage: "book.open") }
                    Button { onCycleColor() } label: { Label("Change Cover Color", systemImage: "paintpalette") }
                    Button { onRename() } label: { Label("Rename…", systemImage: "pencil") }
                    Button { onDuplicate() } label: { Label("Duplicate", systemImage: "doc.on.doc") }
                    Divider()
                    Button(role: .destructive) { onDelete() } label: { Label("Move to Trash", systemImage: "trash") }
                } label: {
                    HStack(spacing: 3) {
                        Text(item.name)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Text(item.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
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

    private func fittedSize(aspect: CGFloat, maxW: CGFloat, maxH: CGFloat) -> CGSize {
        var w = maxW
        var h = w / aspect
        if h > maxH {
            h = maxH
            w = h * aspect
        }
        return CGSize(width: max(20, w), height: max(20, h))
    }
}
