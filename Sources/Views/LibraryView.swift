import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var vault: VaultManager
    @State private var showFolderPicker = false
    @State private var showPDFPicker = false
    @State private var searchText = ""
    @State private var openedPDF: URL?
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

    var body: some View {
        Group {
            if let pdf = openedPDF {
                NotebookScreen(pdfURL: pdf) {
                    if let single = standaloneScopedURL, single == pdf {
                        single.stopAccessingSecurityScopedResource()
                        standaloneScopedURL = nil
                    }
                    openedPDF = nil
                    vault.refreshPDFList()
                }
            } else {
                libraryHome
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            DocumentPicker(contentTypes: [.folder]) { url in
                vault.setVaultFolder(url)
            }
        }
        .sheet(isPresented: $showPDFPicker) {
            DocumentPicker(contentTypes: [.pdf]) { url in
                if url.startAccessingSecurityScopedResource() {
                    standaloneScopedURL = url
                }
                openedPDF = url
            }
        }
    }

    private var libraryHome: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                        Spacer()
                    }
                } else {
                    List(filteredPDFs) { item in
                        Button {
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
                    }
                }
            }
            .navigationTitle("Pencil Ink")
            .searchable(text: $searchText, prompt: "Search PDFs in vault")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showPDFPicker = true
                    } label: {
                        Label("Open PDF", systemImage: "doc.badge.plus")
                    }
                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Vault Folder", systemImage: "folder.badge.gearshape")
                    }
                }
            }
        }
    }

    private var emptyVaultView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 56))
                .foregroundColor(.blue)
            Text("Connect Your Obsidian Vault")
                .font(.title2.bold())
            Text("Pick your Obsidian vault folder once. Pencil Ink opens your PDFs in-place and saves strokes directly into the same .ink.json files Obsidian uses.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button {
                showFolderPicker = true
            } label: {
                Text("Choose Vault Folder")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            Button("Or Open a Single PDF") {
                showPDFPicker = true
            }
            .font(.subheadline)
            .padding(.top, 4)
            Spacer()
        }
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
        }
    }
}
