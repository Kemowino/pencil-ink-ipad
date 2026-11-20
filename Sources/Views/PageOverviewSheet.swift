import SwiftUI

private enum OverviewTab: Int, CaseIterable {
    case thumbnails = 0
    case bookmarks = 1
    case outlines = 2
}

struct PageOverviewSheet: View {
    @ObservedObject var toolState: NotebookToolState
    let controllerBox: PDFNotebookRepresentable.ControllerBox
    var startInSearch: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var activeTab: OverviewTab = .thumbnails
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var outlineEntries: [PDFOutlineEntry] = []
    @State private var searchQuery: String = ""
    @State private var searchHits: [PDFSearchHit] = []
    @State private var isSearchingText: Bool = false

    private var slots: [PageSlot] {
        let _ = toolState.layoutRevision
        return toolState.pageSlots
    }

    private var displayedSlots: [PageSlot] {
        if activeTab == .bookmarks {
            return slots.filter { toolState.bookmarkedKeys.contains($0.key) }
        }
        return slots
    }

    private var trimmedSearch: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var directPageJumpNumber: Int? {
        guard let n = Int(trimmedSearch), n >= 1, n <= slots.count else { return nil }
        return n
    }

    private let columns = [
        GridItem(.adaptive(minimum: 158, maximum: 210), spacing: 20, alignment: .top)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Goodnotes 3-Tab Header: Thumbnails | Bookmarks | Outlines
                Picker("View", selection: $activeTab) {
                    Text("Thumbnails").tag(OverviewTab.thumbnails)
                    Text("Bookmarks (\(toolState.bookmarkedKeys.count))").tag(OverviewTab.bookmarks)
                    Text("Outlines").tag(OverviewTab.outlines)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                if toolState.removedPagesCount > 0 {
                    HStack {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .foregroundColor(.orange)
                        Text("\(toolState.removedPagesCount) hidden PDF page\(toolState.removedPagesCount == 1 ? "" : "s")")
                            .font(.subheadline)
                        Spacer()
                        Button("Restore All") {
                            controllerBox.vc?.restoreAllRemovedPages()
                            thumbnails.removeAll()
                        }
                        .font(.subheadline.bold())
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.orange.opacity(0.14))
                }

                if !trimmedSearch.isEmpty {
                    searchResultsView
                } else if activeTab == .outlines {
                    outlineView
                } else if displayedSlots.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "bookmark")
                            .font(.system(size: 40, weight: .light))
                            .foregroundColor(.secondary)
                        Text("No Bookmarked Pages")
                            .font(.headline)
                        Text("Tap the ribbon on the corner of any page thumbnail to bookmark it.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Spacer()
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 22) {
                                ForEach(displayedSlots) { slot in
                                    goodnotesPageCard(for: slot)
                                        .id(slot.key)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                        }
                        .onAppear {
                            let curIdx = max(0, min(slots.count - 1, toolState.currentPage - 1))
                            if curIdx < slots.count {
                                proxy.scrollTo(slots[curIdx].key, anchor: .center)
                            }
                        }
                    }
                }
            }
            .navigationTitle(startInSearch ? "Search & Pages" : "Thumbnails")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search PDF text or enter page #"
            )
            .onChange(of: searchQuery) { newQuery in
                runSearch(for: newQuery)
            }
            .onAppear {
                outlineEntries = controllerBox.vc?.extractPDFOutline() ?? []
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(PaperTemplate.allCases) { tpl in
                            Button {
                                controllerBox.vc?.insertBlankPage(after: max(0, toolState.currentPage - 1), template: tpl)
                                Haptics.light()
                            } label: {
                                Label("Add \(tpl.title) Page", systemImage: "doc.badge.plus")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func goodnotesPageCard(for slot: PageSlot) -> some View {
        let isCurrent = (slot.index == toolState.currentPage - 1)
        let isMarked = toolState.bookmarkedKeys.contains(slot.key)
        let aspect = max(0.55, min(1.85, slot.size.width / max(1, slot.size.height)))

        return VStack(spacing: 8) {
            GeometryReader { geo in
                let maxW = max(40, geo.size.width)
                let maxH = max(40, geo.size.height)
                let fitted = fittedSize(aspect: aspect, maxW: maxW, maxH: maxH)

                ZStack(alignment: .bottom) {
                    Color.clear
                    ZStack(alignment: .topTrailing) {
                        Button {
                            controllerBox.vc?.jumpToPage(slot.index + 1, animated: true)
                            Haptics.selection()
                            dismiss()
                        } label: {
                            Group {
                                if let img = thumbnails[slot.key] {
                                    Image(uiImage: img)
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fit)
                                } else {
                                    Rectangle()
                                        .fill(Color.white)
                                        .overlay(ProgressView().tint(.gray))
                                }
                            }
                            .frame(width: fitted.width, height: fitted.height)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(
                                        isCurrent ? Color.accentColor : Color.primary.opacity(0.14),
                                        lineWidth: isCurrent ? 2.6 : 0.7
                                    )
                            )
                            #if !targetEnvironment(macCatalyst)
                    .shadow(color: .black.opacity(0.20), radius: 5, y: 2)
                    #endif
                        }
                        .buttonStyle(.plain)

                        // Goodnotes 1-tap Bookmark Ribbon directly on thumbnail corner
                        Button {
                            controllerBox.vc?.toggleBookmark(for: slot.key)
                            Haptics.light()
                        } label: {
                            Image(systemName: isMarked ? "bookmark.fill" : "bookmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(isMarked ? .orange : .secondary.opacity(0.75))
                                .padding(6)
                                .background(
                                    Circle().fill(
                                        colorScheme == .dark
                                            ? Color.black.opacity(0.55)
                                            : Color.white.opacity(0.88)
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(5)
                    }
                }
                .frame(width: maxW, height: maxH, alignment: .bottom)
            }
            .frame(height: 168)
            .clipped()
            .onAppear {
                loadThumbnail(for: slot)
            }

            // Iconic Goodnotes Page Number + Dropdown Chevron (`1 ⌄`)
            Menu {
                Button {
                    controllerBox.vc?.jumpToPage(slot.index + 1, animated: true)
                    dismiss()
                } label: {
                    Label("Go to Page \(slot.index + 1)", systemImage: "arrow.right.circle")
                }
                Menu {
                    ForEach(PaperTemplate.allCases) { tpl in
                        Button {
                            controllerBox.vc?.insertBlankPage(after: slot.index, template: tpl)
                            Haptics.light()
                        } label: {
                            Label(tpl.title + " Page", systemImage: "doc.badge.plus")
                        }
                    }
                } label: {
                    Label("Add Page After", systemImage: "plus.rectangle.on.rectangle")
                }
                Button {
                    controllerBox.vc?.duplicatePage(at: slot.index)
                    Haptics.light()
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                Button {
                    controllerBox.vc?.toggleBookmark(for: slot.key)
                    Haptics.light()
                } label: {
                    Label(isMarked ? "Remove Bookmark" : "Add Bookmark", systemImage: isMarked ? "bookmark.slash" : "bookmark")
                }
                Divider()
                Button(role: .destructive) {
                    controllerBox.vc?.deletePage(at: slot.index)
                    Haptics.light()
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(slots.count <= 1)
            } label: {
                HStack(spacing: 3) {
                    Text("\(slot.index + 1)")
                        .font(.system(size: 13, weight: isCurrent ? .bold : .medium, design: .rounded))
                        .foregroundColor(isCurrent ? .accentColor : .primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
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

    private var searchResultsView: some View {
        List {
            if let pageNum = directPageJumpNumber {
                Section("Go to Page") {
                    Button {
                        controllerBox.vc?.jumpToPage(pageNum, animated: true)
                        dismiss()
                    } label: {
                        Label("Jump to Page \(pageNum)", systemImage: "arrow.right.circle.fill")
                            .fontWeight(.semibold)
                            .foregroundColor(.accentColor)
                    }
                }
            }

            let matchingOutline = outlineEntries.filter {
                $0.title.localizedCaseInsensitiveContains(trimmedSearch)
            }
            if !matchingOutline.isEmpty {
                Section("Outline Matches (\(matchingOutline.count))") {
                    ForEach(matchingOutline.prefix(25)) { entry in
                        Button {
                            controllerBox.vc?.jumpToPage(entry.pageNumber, animated: true)
                            dismiss()
                        } label: {
                            HStack {
                                Text(entry.title).foregroundColor(.primary).lineLimit(2)
                                Spacer()
                                Text("p. \(entry.pageNumber)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }

            Section("Text Matches") {
                if isSearchingText {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching document…").font(.subheadline).foregroundColor(.secondary)
                    }
                } else if searchHits.isEmpty {
                    Text(trimmedSearch.count < 2 ? "Type at least 2 characters to search PDF text." : "No matching text found.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(searchHits) { hit in
                        Button {
                            controllerBox.vc?.jumpToPage(hit.pageNumber, animated: true)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Page \(hit.pageNumber)")
                                    .font(.caption.bold())
                                    .foregroundColor(.accentColor)
                                Text(hit.snippet)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var outlineView: some View {
        Group {
            if outlineEntries.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.secondary)
                    Text("No Outline")
                        .font(.headline)
                    Text("This document does not contain embedded PDF chapters. Use the search bar above to find text or jump to any page.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                    Spacer()
                }
            } else {
                List(outlineEntries) { entry in
                    Button {
                        controllerBox.vc?.jumpToPage(entry.pageNumber, animated: true)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Text(entry.title)
                                .font(.system(size: entry.depth == 0 ? 15 : 14, weight: entry.depth == 0 ? .semibold : .regular))
                                .foregroundColor(.primary)
                                .padding(.leading, CGFloat(entry.depth) * 16)
                                .lineLimit(2)
                            Spacer()
                            Text("\(entry.pageNumber)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func runSearch(for query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            searchHits = []
            isSearchingText = false
            return
        }
        isSearchingText = true
        controllerBox.vc?.searchPDFText(q) { hits in
            if self.trimmedSearch == q {
                self.searchHits = hits
                self.isSearchingText = false
            }
        }
    }

    private func loadThumbnail(for slot: PageSlot) {
        if thumbnails[slot.key] != nil { return }
        controllerBox.vc?.renderThumbnailAsync(for: slot, targetWidth: 260) { img in
            if let img = img {
                thumbnails[slot.key] = img
            }
        }
    }
}
