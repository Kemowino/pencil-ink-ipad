import Foundation
import UIKit
import CoreGraphics

struct PendingIncomingFile: Identifiable {
    let id = UUID()
    let stagedPDFURL: URL
    let originalURL: URL
    let suggestedTitle: String
    let pageCount: Int
    let fileSizeBytes: Int64
    let previewImage: UIImage?
    let wasConvertedFromImage: Bool
    let existingVaultItem: PDFItem?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}

/// Handles files sent to Pencil Ink via the iPadOS/iOS Share Sheet ("Open in Pencil Ink" / "Copy to Pencil Ink")
/// or Files app. Stages files safely into a temporary PDF (even converting shared images to 1-page PDFs!)
/// and prompts the user with `IncomingImportSheet` to choose a destination folder before opening.
@MainActor
final class IncomingFileManager: ObservableObject {
    @Published var pendingFile: PendingIncomingFile? = nil
    @Published var isStagingFile: Bool = false
    @Published var stagingError: String? = nil

    private var queuedFiles: [PendingIncomingFile] = []
    private let lastFolderKey = "pencilink.ios.lastImportFolder.v1"
    private let stagingQueue = DispatchQueue(label: "com.pencilink.incoming.stage", qos: .userInitiated)

    var lastImportFolder: String {
        get { UserDefaults.standard.string(forKey: lastFolderKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastFolderKey) }
    }

    func handleIncomingURL(_ url: URL, vault: VaultManager) {
        guard url.isFileURL else { return }
        isStagingFile = true
        stagingError = nil

        // Check if this file already lives inside the user's connected vault
        var existingMatch: PDFItem? = nil
        if vault.isURLInsideVault(url) {
            let std = url.standardizedFileURL.resolvingSymlinksInPath().path
            if let hit = vault.pdfs.first(where: {
                $0.url.standardizedFileURL.resolvingSymlinksInPath().path == std
            }) {
                existingMatch = hit
            } else if url.pathExtension.lowercased() == "pdf" {
                let rel = vault.relativePath(for: url)
                let relFolder = (rel as NSString).deletingLastPathComponent
                let cleanFolder = (relFolder == "." || relFolder == "/") ? "" : relFolder
                let inkExists = FileManager.default.fileExists(atPath: url.path + ".ink.json")
                existingMatch = PDFItem(
                    id: std,
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    relativeFolder: cleanFolder,
                    relativePath: rel,
                    modifiedAt: Date(),
                    hasInk: inkExists,
                    isHobonichi: rel.hasPrefix("Journals/") || url.lastPathComponent.lowercased().contains("hobonichi")
                )
            }
        }

        let docsDirPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .standardizedFileURL.resolvingSymlinksInPath().path ?? ""
        let inboxPrefix = docsDirPath.isEmpty ? "" : (docsDirPath + "/Inbox/")

        stagingQueue.async { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let rawTitle = url.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suggestedTitle = rawTitle.isEmpty ? "Imported Document" : rawTitle
            let ext = url.pathExtension.lowercased()

            let stagedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("pink-incoming-\(UUID().uuidString).pdf")

            var convertedImage = false
            do {
                let data = try Data(contentsOf: url)
                let isPDFHeader = data.count >= 4 && data.prefix(4) == Data("%PDF".utf8)

                if ext == "pdf" || isPDFHeader {
                    try data.write(to: stagedURL, options: .atomic)
                } else if let img = UIImage(data: data), let cgImg = img.cgImage {
                    // Convert shared image (PNG/JPEG/HEIC screenshot or slide) cleanly into a 1-page PDF!
                    convertedImage = true
                    let oriented = Self.normalizedOrientationImage(img)
                    let imgW = max(1.0, oriented.size.width)
                    let imgH = max(1.0, oriented.size.height)
                    // Fit into natural note-taking page scale (~595 pt width for portrait, ~842 pt for landscape)
                    let targetW: CGFloat = (imgW > imgH) ? 842.0 : 595.0
                    let targetH = max(120.0, targetW * (imgH / imgW))
                    let pageSz = CGSize(width: targetW.rounded(), height: targetH.rounded())
                    let pdfData = PlatformGraphics.makePDFData(pageSizes: [pageSz]) { _, ctx, rect in
                        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                        ctx.fill(rect)
                        ctx.saveGState()
                        ctx.translateBy(x: 0, y: rect.height)
                        ctx.scaleBy(x: 1, y: -1)
                        if let drawCG = oriented.cgImage ?? Optional(cgImg) {
                            ctx.draw(drawCG, in: rect)
                        }
                        ctx.restoreGState()
                    }
                    try pdfData.write(to: stagedURL, options: .atomic)
                } else {
                    throw NSError(
                        domain: "IncomingFileManager",
                        code: 10,
                        userInfo: [NSLocalizedDescriptionKey: "Unsupported file type (.\(ext.isEmpty ? "unknown" : ext)). Share a PDF or image."]
                    )
                }

                // Clean up ephemeral copy iOS puts in `Documents/Inbox/` so it never clutters Local App Folder
                let stdIncoming = url.standardizedFileURL.resolvingSymlinksInPath().path
                if !inboxPrefix.isEmpty && stdIncoming.hasPrefix(inboxPrefix) {
                    try? FileManager.default.removeItem(at: url)
                }

                let attrs = try? FileManager.default.attributesOfItem(atPath: stagedURL.path)
                let sizeBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

                var pageCount = 1
                var preview: UIImage? = nil
                if let cgDoc = CGPDFDocument(stagedURL as CFURL) {
                    pageCount = max(1, cgDoc.numberOfPages)
                    if let p1 = cgDoc.page(at: 1) {
                        let sz = PlatformGraphics.normalizedPageSize(for: p1)
                        preview = PlatformGraphics.renderPDFCoverImage(cgPage: p1, pageSize: sz, targetWidth: 220, maxPixels: 200_000)
                    }
                }

                let staged = PendingIncomingFile(
                    stagedPDFURL: stagedURL,
                    originalURL: url,
                    suggestedTitle: suggestedTitle,
                    pageCount: pageCount,
                    fileSizeBytes: sizeBytes,
                    previewImage: preview,
                    wasConvertedFromImage: convertedImage,
                    existingVaultItem: existingMatch
                )

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isStagingFile = false
                    if self.pendingFile == nil {
                        self.pendingFile = staged
                    } else {
                        self.queuedFiles.append(staged)
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isStagingFile = false
                    self.stagingError = error.localizedDescription
                }
            }
        }
    }

    func finishPending(deleteStagedFile: Bool = true) {
        if let cur = pendingFile, deleteStagedFile {
            try? FileManager.default.removeItem(at: cur.stagedPDFURL)
        }
        pendingFile = nil
        if !queuedFiles.isEmpty {
            let next = queuedFiles.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.pendingFile = next
            }
        }
    }

    private nonisolated static func normalizedOrientationImage(_ img: UIImage) -> UIImage {
        if img.imageOrientation == .up { return img }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: img.size, format: format)
        return renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: img.size))
        }
    }
}
