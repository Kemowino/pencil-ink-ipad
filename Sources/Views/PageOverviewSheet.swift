import SwiftUI

private enum OverviewTab: Int, CaseIterable {
    case allPages = 0
    case bookmarks = 1
    case outline = 2

    var title: String {
        switch self {
        case .allPages: return "Pages"
        case .bookmarks: return "Bookmarks"
        case .outline: return "Contents"
        }
    }
}

struct PageOverviewSheet: View {
    @ObservedObject var toolState: NotebookToolState
    let controllerBox: PDFNotebookRepresentable.ControllerBox
    @Environment(\.dismiss) private var dismiss

    @State private var activeTab: OverviewTab = .allPages
    @State private var selectedIndex: Int = 0
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var outlineEntries: [PDFOutlineEntry] = []
    @State private var searchQuery: String = ""
    @State private var searchHits: [PDFSearchHit] = []
    @State private var isSearchingText: Bool = false

    private var slots: [PageSlot] {
        toolState.pageSlots
    }

    private var displayedSlots: [PageSlot] {
        if activeTab == .bookmarks {
            return slots.filter { toolState.bookmarkedKeys.contains($0.key) }
        }
        return slots
    }

    private var activeTargetIndex: Int {
        if selectedIndex >= 0 && selectedIndex < slots.count {
            return selectedIndex
        }
        return max(0, min(slots.count - 1, toolState.currentPage - 1))
    }

    private var isTargetBookmarked: Bool {
        guard activeTargetIndex >= 0 && activeTargetIndex < slots.count else { return false }
        return toolState.bookmarkedKeys.contains(slots[activeTargetIndex].key)
    }

    private var trimmedSearch: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var directPageJumpNumber: Int? {
        guard let n = Int(trimmedSearch), n >= 1, n <= slots.count else { return nil }
        return n
    }

    private let columns = [
        GridItem(.adaptive(minimum: 155, maximum: 220), spacing: 18)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented View Switcher: Pages | Bookmarks | Contents (Outline)
                Picker("View", selection: $activeTab) {
                    Text("Pages (\(slots.count))").tag(OverviewTab.allPages)
                    Text("Bookmarks (\(toolState.bookmarkedKeys.count))").tag(OverviewTab.bookmarks)
                    Text("Contents").tag(OverviewTab.outline)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Removed pages restore banner
                if toolState.removedPagesCount > 0 {
                    HStack {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .foregroundColor(.orange)
                        Text("\(toolState.removedPagesCount) PDF page\(toolState.removedPagesCount == 1 ? "" : "s") hidden")
                            .font(.subheadline)
                        Spacer()
                        Button("Restore All") {
                            controllerBox.vc?.restoreAllRemovedPages()
                            thumbnails.removeAll()
                        }
                        .font(.subheadline.bold())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.14))
                }

                // Active Content: Search Results OR Pages/Bookmarks Grid OR PDF Outline
                if !trimmedSearch.isEmpty {
                    searchResultsView
                } else if activeTab == .outline {
                    outlineView
                } else if displayedSlots.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "bookmark.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No Bookmarked Pages")
                            .font(.headline)
                        Text("Select any page and tap Bookmark below, or tap the bookmark icon in the toolbar.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                        Spacer()
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(displayedSlots) { slot in
                                    thumbnailCard(for: slot)
                                        .id(slot.key)
                                }
                            }
                            .padding(16)
                        }
                        .onAppear {
                            selectedIndex = max(0, min(slots.count - 1, toolState.currentPage - 1))
                            if selectedIndex < slots.count {
                                proxy.scrollTo(slots[selectedIndex].key, anchor: .center)
                            }
                        }
                    }
                }

                if activeTab != .outline && trimmedSearch.isEmpty {
                    Divider()
                    bottomActionBar
                }
            }
            .navigationTitle("Overview & Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: "Search text in PDF or type page #")
            .onChange(of: searchQuery) { newQuery in
                runSearch(for: newQuery)
            }
            .onAppear {
                selectedIndex = max(0, min(slots.count - 1, toolState.currentPage - 1))
                outlineEntries = controllerBox.vc?.extractPDFOutline() ?? []
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if activeTab != .outline && trimmedSearch.isEmpty {
                        Button("Jump to Selected") {
                            controllerBox.vc?.jumpToPage(activeTargetIndex + 1, animated: true)
                            dismiss()
                        }
                        .disabled(slots.isEmpty)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var searchResultsView: some View {
        List {
            if let pageNum = directPageJumpNumber {
                Section("Quick Page Jump") {
                    Button {
                        controllerBox.vc?.jumpToPage(pageNum, animated: true)
                        dismiss()
                    } label: {
                        Label("Jump directly to Page \(pageNum)", systemImage: "arrow.right.circle.fill")
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                    }
                }
            }

            let matchingOutline = outlineEntries.filter {
                $0.title.localizedCaseInsensitiveContains(trimmedSearch)
            }
            if !matchingOutline.isEmpty {
                Section("Matching Chapters (\(matchingOutline.count))") {
                    ForEach(matchingOutline.prefix(25)) { entry in
                        Button {
                            controllerBox.vc?.jumpToPage(entry.pageNumber, animated: true)
                            dismiss()
                        } label: {
                            HStack {
                                Text(entry.title)
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                Spacer()
                                Text("p. \(entry.pageNumber)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }

            Section("Text Matches in PDF") {
                if isSearchingText {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching document…")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
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
                                    .foregroundColor(.blue)
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
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No Table of Contents")
                        .font(.headline)
                    Text("This PDF doesn't include embedded outline chapters. Use the search bar above to search text or jump to any page.")
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

    private var bottomActionBar: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(PaperTemplate.allCases) { tpl in
                    Button {
                        controllerBox.vc?.insertBlankPage(after: activeTargetIndex, template: tpl)
                        selectedIndex = min(toolState.pageSlots.count - 1, activeTargetIndex + 1)
                    } label: {
                        Label(tpl.title + " Page", systemImage: iconForTemplate(tpl))
                    }
                }
            } label: {
                actionTab(icon: "plus.rectangle.on.rectangle", label: "Add Page", tint: .blue)
            }

            Button {
                controllerBox.vc?.duplicatePage(at: activeTargetIndex)
                selectedIndex = min(toolState.pageSlots.count - 1, activeTargetIndex + 1)
            } label: {
                actionTab(icon: "doc.on.doc", label: "Duplicate", tint: .blue)
            }

            Button {
                if activeTargetIndex < slots.count {
                    controllerBox.vc?.toggleBookmark(for: slots[activeTargetIndex].key)
                }
            } label: {
                actionTab(
                    icon: isTargetBookmarked ? "bookmark.fill" : "bookmark",
                    label: isTargetBookmarked ? "Unmark" : "Bookmark",
                    tint: isTargetBookmarked ? .orange : .blue
                )
            }

            Button {
                controllerBox.vc?.deletePage(at: activeTargetIndex)
                selectedIndex = max(0, min(toolState.pageSlots.count - 1, activeTargetIndex))
            } label: {
                actionTab(icon: "trash", label: "Delete", tint: .red)
            }
            .disabled(slots.count <= 1)
        }
        .padding(.vertical, 8)
        .background(.bar)
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

    private func thumbnailCard(for slot: PageSlot) -> some View {
        let isSelected = slot.index == activeTargetIndex
        let isCurrent = slot.index == toolState.currentPage - 1
        let isMarked = toolState.bookmarkedKeys.contains(slot.key)
        let aspect = max(0.5, min(2.0, slot.size.width / max(1, slot.size.height)))

        return VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let img = thumbnails[slot.key] {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(Color.white)
                            .aspectRatio(aspect, contentMode: .fit)
                            .overlay(ProgressView().tint(.gray))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.blue : Color.primary.opacity(0.14), lineWidth: isSelected ? 3 : 0.8)
                )
                .shadow(color: .black.opacity(0.24), radius: 6, y: 2)

                if isMarked {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.orange)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .padding(.leading, 8)
                        .padding(.top, -2)
                }

                if isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.blue)
                                .background(Circle().fill(Color.white).padding(2))
                                .padding(6)
                        }
                        Spacer()
                    }
                }
            }
            .onTapGesture {
                Haptics.selection()
                if selectedIndex == slot.index {
                    controllerBox.vc?.jumpToPage(slot.index + 1, animated: true)
                    dismiss()
                } else {
                    selectedIndex = slot.index
                }
            }
            .onAppear {
                loadThumbnail(for: slot)
            }

            HStack(spacing: 4) {
                Text("\(slot.index + 1)")
                    .font(.system(size: 12, weight: isCurrent ? .bold : .semibold, design: .rounded))
                    .foregroundColor(isCurrent ? .blue : .secondary)
                if slot.isAddedPage {
                    Text(slot.srcN != nil ? "· copy" : "· \(slot.template.title.lowercased())")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
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

    private func actionTab(icon: String, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(tint)
        .frame(maxWidth: .infinity)
    }

    private func iconForTemplate(_ tpl: PaperTemplate) -> String {
        switch tpl {
        case .blank: return "doc"
        case .lined: return "doc.text"
        case .grid: return "grid"
        case .dot: return "circle.grid.3x3"
        case .cornell: return "rectangle.split.2x2"
        }
    }
}
