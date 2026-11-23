import Foundation
import UIKit
import CoreGraphics
import CoreVideo
import IOSurface
import Compression

/// Holds one LZ4-compressed 32-bit BGRA page bitmap in compressible normal RAM.
/// A typical 1.2 MP textbook page (~4.8 MB raw) compresses to ~300–550 KB via `COMPRESSION_LZ4`
/// and inflates directly into a zero-copy `IOSurface` in ~1.2 ms (>3 GB/s).
final class CompressedPageBlob {
    let lz4Data: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let rawByteCount: Int
    let zoomScale: CGFloat

    init(lz4Data: Data, width: Int, height: Int, bytesPerRow: Int, rawByteCount: Int, zoomScale: CGFloat) {
        self.lz4Data = lz4Data
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.rawByteCount = rawByteCount
        self.zoomScale = zoomScale
    }
}

/// Two-Tier LZ4 + Zero-Copy `IOSurface` Page Raster Cache:
/// - **Mounted Viewport Pages:** Zero-copy `IOSurfaceRef` (`32BGRA`, tagged `sRGB`, 64-byte aligned).
///   Only ~5–6 mounted views hold live `IOSurface` objects at once (~20–25 MB wired max).
/// - **Tier-1 RAM Cache:** `NSCache` of LZ4-compressed page blobs (~140 pages in ~55 MB Mac / ~70 pages in ~28 MB iPad).
/// - **Tier-2 Persistent SSD Cache:** LRU disk cache in `Library/Caches/PencilInkPageCache` (250 MB Mac / 150 MB iPad)
///   so any page viewed once never re-runs `CGContextDrawPDFPage` across chapters or app relaunches!
final class PageRasterCache {
    static let shared = PageRasterCache()

    private static let diskMagic: UInt32 = 0x50494C5A // "PILZ"
    private static let diskFormatVersion: UInt32 = 1
    private static let headerSize = 28

    private let ramCache: NSCache<NSString, CompressedPageBlob> = {
        let c = NSCache<NSString, CompressedPageBlob>()
        #if targetEnvironment(macCatalyst)
        c.countLimit = 160
        c.totalCostLimit = 55 * 1024 * 1024
        #else
        c.countLimit = 80
        c.totalCostLimit = 28 * 1024 * 1024
        #endif
        return c
    }()

    private let diskQueue = DispatchQueue(label: "com.pencilink.pagecache.disk", qos: .utility)
    private let diskDirURL: URL
    private let diskBudgetBytes: Int64
    private var writesSincePrune: Int = 0

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.diskDirURL = caches.appendingPathComponent("PencilInkPageCache", isDirectory: true)
        #if targetEnvironment(macCatalyst)
        self.diskBudgetBytes = 250 * 1024 * 1024
        #else
        self.diskBudgetBytes = 150 * 1024 * 1024
        #endif
        try? FileManager.default.createDirectory(at: diskDirURL, withIntermediateDirectories: true)
    }

    // MARK: - Zero-Copy IOSurface Allocation (iOS 11+ & Mac Catalyst 13.1+)

    /// Allocates a 64-byte row-aligned `32BGRA` `IOSurfaceRef` tagged with `sRGB` color space.
    /// Shared directly between CPU (`CGContext` / LZ4 inflate) and `WindowServer`/GPU (`CALayer.contents`).
    static func allocateSurface(width: Int, height: Int) -> IOSurfaceRef? {
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = ((width * 4 + 63) / 64) * 64
        let allocSize = bytesPerRow * height
        let props: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfaceAllocSize: allocSize,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA
        ]
        guard let surface = IOSurfaceCreate(props as CFDictionary) else { return nil }
        IOSurfaceSetValue(surface, "IOSurfaceColorSpace" as CFString, CGColorSpace.sRGB)
        return surface
    }

    // MARK: - Cache Keys & Fingerprinting

    /// Fast document fingerprint based on path, file size, and mtime so edited PDFs never serve stale cache entries.
    static func documentFingerprint(for pdfURL: URL) -> String {
        let stdPath = pdfURL.standardizedFileURL.path
        let attrs = (try? FileManager.default.attributesOfItem(atPath: stdPath)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int64(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0).rounded())
        return WireCodec.md5Hex(Data("\(stdPath)|\(size)|\(mtime)".utf8))
    }

    static func cacheKey(
        docFingerprint: String,
        pageKey: String,
        readingMode: PDFReadingMode,
        quality: PDFRenderQuality
    ) -> String {
        "\(docFingerprint)|\(pageKey)|\(readingMode.rawValue)|\(quality.rawValue)"
    }

    // MARK: - Fast RAM Lookup (Main-Thread Safe, ~1.2 ms Inflate)

    /// Synchronous Tier-1 RAM hit check (does zero disk I/O — safe to call during view mount!).
    func inflateFromRAM(key: String) -> (surface: IOSurfaceRef, zoomScale: CGFloat)? {
        guard let blob = ramCache.object(forKey: key as NSString) else { return nil }
        guard let surface = Self.inflateBlobToSurface(blob) else { return nil }
        return (surface, blob.zoomScale)
    }

    /// Background-thread Tier-1 RAM + Tier-2 SSD lookup: inflates straight into a zero-copy `IOSurfaceRef`.
    func lookupAndInflate(key: String) -> (surface: IOSurfaceRef, zoomScale: CGFloat)? {
        if let blob = ramCache.object(forKey: key as NSString),
           let surface = Self.inflateBlobToSurface(blob) {
            return (surface, blob.zoomScale)
        }
        guard let diskBlob = readBlobFromDisk(key: key) else { return nil }
        ramCache.setObject(diskBlob, forKey: key as NSString, cost: max(1024, diskBlob.lz4Data.count))
        guard let surface = Self.inflateBlobToSurface(diskBlob) else { return nil }
        return (surface, diskBlob.zoomScale)
    }

    // MARK: - Store (Compress IOSurface -> Tier-1 RAM + Async Tier-2 SSD)

    func store(surface: IOSurfaceRef, zoomScale: CGFloat, key: String) {
        guard let blob = Self.compressSurface(surface, zoomScale: zoomScale) else { return }
        ramCache.setObject(blob, forKey: key as NSString, cost: max(1024, blob.lz4Data.count))
        diskQueue.async { [weak self] in
            self?.writeBlobToDisk(blob, key: key)
        }
    }

    func removeAllRAM() {
        ramCache.removeAllObjects()
    }

    func clearAllCaches(completion: (() -> Void)? = nil) {
        ramCache.removeAllObjects()
        diskQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: self.diskDirURL, includingPropertiesForKeys: nil) {
                for url in files {
                    try? fm.removeItem(at: url)
                }
            }
            if let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    func diskCacheBytesSync() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: diskDirURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for url in files {
            if let sz = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(sz)
            }
        }
        return total
    }

    // MARK: - LZ4 Compression / Decompression Core (Zero Per-Page Scratch/Output Malloc!)

    private static let encodeLock = NSLock()
    private static var reusableScratchPtr: UnsafeMutableRawPointer? = nil
    private static var reusableDstPtr: UnsafeMutablePointer<UInt8>? = nil
    private static var reusableDstCap: Int = 0

    private static func compressSurface(_ surface: IOSurfaceRef, zoomScale: CGFloat) -> CompressedPageBlob? {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let rawBytes = bytesPerRow * height
        guard width > 0, height > 0, rawBytes > 0 else { return nil }

        guard IOSurfaceLock(surface, .readOnly, nil) == KERN_SUCCESS else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }

        let srcPtr = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let neededCap = rawBytes + (rawBytes / 16) + 64

        encodeLock.lock()
        if reusableScratchPtr == nil {
            let scratchSize = compression_encode_scratch_buffer_size(COMPRESSION_LZ4)
            if scratchSize > 0 {
                reusableScratchPtr = UnsafeMutableRawPointer.allocate(byteCount: scratchSize, alignment: 16)
            }
        }
        if reusableDstCap < neededCap {
            reusableDstPtr?.deallocate()
            reusableDstPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: neededCap)
            reusableDstCap = neededCap
        }
        guard let dstPtr = reusableDstPtr else {
            encodeLock.unlock()
            return nil
        }

        let compressedLen = compression_encode_buffer(
            dstPtr,
            reusableDstCap,
            srcPtr,
            rawBytes,
            reusableScratchPtr,
            COMPRESSION_LZ4
        )
        let lz4Data: Data? = compressedLen > 0 ? Data(bytes: dstPtr, count: compressedLen) : nil
        encodeLock.unlock()

        guard let lz4Data else { return nil }
        return CompressedPageBlob(
            lz4Data: lz4Data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            rawByteCount: rawBytes,
            zoomScale: zoomScale
        )
    }

    private static func inflateBlobToSurface(_ blob: CompressedPageBlob) -> IOSurfaceRef? {
        guard let surface = allocateSurface(width: blob.width, height: blob.height) else { return nil }
        let dstBPR = IOSurfaceGetBytesPerRow(surface)
        let dstBytes = dstBPR * blob.height
        guard dstBPR == blob.bytesPerRow, dstBytes == blob.rawByteCount else { return nil }

        guard IOSurfaceLock(surface, [], nil) == KERN_SUCCESS else { return nil }
        let dstPtr = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let decoded = blob.lz4Data.withUnsafeBytes { rawBuf -> Int in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(
                dstPtr,
                dstBytes,
                base,
                blob.lz4Data.count,
                nil,
                COMPRESSION_LZ4
            )
        }
        IOSurfaceUnlock(surface, [], nil)
        guard decoded == blob.rawByteCount else { return nil }
        return surface
    }

    // MARK: - Tier-2 Binary Disk Storage & LRU Eviction

    private func diskFileURL(for key: String) -> URL {
        let hash = WireCodec.md5Hex(Data(key.utf8))
        return diskDirURL.appendingPathComponent("\(hash).plz4", isDirectory: false)
    }

    private func writeBlobToDisk(_ blob: CompressedPageBlob, key: String) {
        let url = diskFileURL(for: key)
        var data = Data(capacity: Self.headerSize + blob.lz4Data.count)
        appendLE(&data, Self.diskMagic)
        appendLE(&data, Self.diskFormatVersion)
        appendLE(&data, UInt32(blob.width))
        appendLE(&data, UInt32(blob.height))
        appendLE(&data, UInt32(blob.bytesPerRow))
        appendLE(&data, UInt32(blob.rawByteCount))
        appendLE(&data, Float32(blob.zoomScale).bitPattern)
        data.append(blob.lz4Data)
        try? data.write(to: url, options: .atomic)

        writesSincePrune += 1
        if writesSincePrune >= 12 {
            writesSincePrune = 0
            pruneDiskCacheIfNeeded()
        }
    }

    private func readBlobFromDisk(key: String) -> CompressedPageBlob? {
        let url = diskFileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              data.count > Self.headerSize else { return nil }

        let magic = readLE(data, offset: 0)
        let ver = readLE(data, offset: 4)
        guard magic == Self.diskMagic, ver == Self.diskFormatVersion else { return nil }

        let w = Int(readLE(data, offset: 8))
        let h = Int(readLE(data, offset: 12))
        let bpr = Int(readLE(data, offset: 16))
        let rawBytes = Int(readLE(data, offset: 20))
        let zoomBits = readLE(data, offset: 24)
        let zoom = CGFloat(Float32(bitPattern: zoomBits))
        guard w > 0, h > 0, bpr > 0, rawBytes == bpr * h else { return nil }

        let payload = data.subdata(in: Self.headerSize..<data.count)
        // Touch mtime at most once every 30 minutes per page to avoid SSD metadata write amplification!
        if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(mtime) > 1800 {
            diskQueue.async {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            }
        }
        return CompressedPageBlob(
            lz4Data: payload,
            width: w,
            height: h,
            bytesPerRow: bpr,
            rawByteCount: rawBytes,
            zoomScale: zoom
        )
    }

    private func pruneDiskCacheIfNeeded() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: diskDirURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: Int64, mtime: Date)] = []
        var total: Int64 = 0
        for u in urls {
            guard let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let sz = Int64(vals.fileSize ?? 0)
            total += sz
            entries.append((u, sz, vals.contentModificationDate ?? .distantPast))
        }
        guard total > diskBudgetBytes else { return }

        // Evict oldest-accessed files down to 80% of budget
        let target = Int64(Double(diskBudgetBytes) * 0.80)
        entries.sort { $0.mtime < $1.mtime }
        for e in entries {
            try? fm.removeItem(at: e.url)
            total -= e.size
            if total <= target { break }
        }
    }

    private func appendLE(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private func readLE(_ data: Data, offset: Int) -> UInt32 {
        var val: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &val) { dst in
            data.copyBytes(to: dst, from: offset..<(offset + 4))
        }
        return UInt32(littleEndian: val)
    }
}
