import SwiftUI

struct PageOverviewSheet: View {
    @ObservedObject var toolState: NotebookToolState
    let controllerBox: PDFNotebookRepresentable.ControllerBox
    @Environment(\.dismiss) private var dismiss

    @State private var filterBookmarks = false
    @State private var selectedIndex: Int = 0
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var showTemplateMenu = false

    private var slots: [PageSlot] {
        toolState.pageSlots
    }

    private var displayedSlots: [PageSlot] {
        if !filterBookmarks { return slots }
        return slots.filter { toolState.bookmarkedKeys.contains($0.key) }
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

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter Segmented Bar
                Picker("Filter", selection: $filterBookmarks) {
                    Text("All Pages (\(slots.count))").tag(false)
                    Text("Bookmarks (\(toolState.bookmarkedKeys.count))").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Removed pages restore bar
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

                // Thumbnail Grid
                if displayedSlots.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "bookmark.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No Bookmarked Pages")
                            .font(.headline)
                        Text("Select a page below and tap Bookmark to pin it here.")
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

                Divider()

                // Bottom Page Action Bar
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
                .background(Color(UIColor.secondarySystemBackground))
            }
            .navigationTitle("Page Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Jump to Selected") {
                        controllerBox.vc?.jumpToPage(activeTargetIndex + 1, animated: true)
                        dismiss()
                    }
                    .disabled(slots.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
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
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.blue : Color.white.opacity(0.18), lineWidth: isSelected ? 3 : 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 5, y: 2)

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
