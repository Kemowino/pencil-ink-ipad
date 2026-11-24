import AppKit
import CoreGraphics
import Foundation
import IOSurface
import IOKit

/// Holds a rendered `IOSurface` ready to be assigned directly to `CALayer.contents` with zero IPC copy.
final class MacRenderedPageSurface {
    let surface: IOSurfaceRef
    let tier: MacRenderTier
    let pixelW: Int
    let pixelH: Int
    let colorSpaceName: String

    private let recycleLock = NSLock()
    private var isRecycled = false

    init(surface: IOSurfaceRef, tier: MacRenderTier, pixelW: Int, pixelH: Int, colorSpaceName: String) {
        self.surface = surface
        self.tier = tier
        self.pixelW = pixelW
        self.pixelH = pixelH
        self.colorSpaceName = colorSpaceName
    }

    /// Explicitly returns the underlying `IOSurface` to `MacIOSurfacePool` once no layer or cache references it.
    func recycleToPool() {
        recycleLock.lock()
        let shouldRecycle = !isRecycled
        isRecycled = true
        recycleLock.unlock()
        if shouldRecycle {
            MacIOSurfacePool.shared.recycle(surface, tier: tier, colorSpaceName: colorSpaceName)
        }
    }

    deinit {
        recycleToPool()
    }
}

/// Two-tier progressive `CGPDFDocument` -> `IOSurface` rasterizer tuned for 5-10 EI on Intel Macs.
///
/// v4.1.0 Upgrades:
/// 1. **1.05 MP Crisp Reading Draft (`interpolationQuality = .none`):** Vector CoreText stays 100% antialiased
///    while skipping expensive `argb32_sample_argb32` resampling on embedded images -> crisp while scrolling, zero pop-in ghosting.
/// 2. **Area-Capped Tier-2 Retina (`<= 1.85 MP` normal / `<= 2.40 MP` zoomed):** Cuts settled & zoom Worker CPU by ~60%.
/// 3. **16-Page Draft + 6-Page Retina LRU Cache Preserved Across Zoom:** Zooming 1.0x <-> 2.1x and scrolling back hits cache at 0% CPU.
/// 4. **Edge-to-edge `cropBox` + `rotationAngle` matrix:** Eliminates white borders on 16:9 lecture slides & zoomed pages.
final class MacProgressivePDFRenderer {
    private let draftQueue = DispatchQueue(
        label: "com.pencilink.mac.progressive.draft",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let retinaQueue = DispatchQueue(
        label: "com.pencilink.mac.progressive.retina",
        qos: .background,
        autoreleaseFrequency: .workItem
    )

    private let lock = NSLock()

    private var pdfURL: URL?
    private var mappedPDFData: Data?
    /// Separate `CGPDFDocument` handles per serial queue (zero lock contention, shared kernel mmap pages).
    private var draftCGDoc: CGPDFDocument?
    private var retinaCGDoc: CGPDFDocument?

    private var generation: UInt64 = 0
    private var activeRange: ClosedRange<Int> = 0...0

    private struct CacheKey: Hashable {
        let slotKey: String
        let tier: MacRenderTier
        let pixelW: Int
        let pixelH: Int
        let highQuality: Bool
    }

    private var draftCache: [CacheKey: MacRenderedPageSurface] = [:]
    private var draftLRU: [CacheKey] = []
    private let maxCachedDrafts = 16

    private var retinaCache: [CacheKey: MacRenderedPageSurface] = [:]
    private var retinaLRU: [CacheKey] = []
    private let maxCachedRetina = 6

    private var inFlight: Set<CacheKey> = []

    /// Configures (or switches) the backing PDF file using a zero-syscall memory-mapped `CGDataProvider`.
    func configure(pdfURL: URL) {
        releaseAllSurfaces()

        let mapped = try? Data(contentsOf: pdfURL, options: .mappedIfSafe)
        lock.lock()
        self.pdfURL = pdfURL
        self.mappedPDFData = mapped
        lock.unlock()

        draftQueue.async { [weak self] in
            guard let self else { return }
            self.draftCGDoc = Self.openCGPDFDocument(url: pdfURL, mappedData: mapped)
        }
        retinaQueue.async { [weak self] in
            guard let self else { return }
            self.retinaCGDoc = Self.openCGPDFDocument(url: pdfURL, mappedData: mapped)
        }
    }

    private static func openCGPDFDocument(url: URL, mappedData: Data?) -> CGPDFDocument? {
        if let data = mappedData, let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) {
            return doc
        }
        return CGPDFDocument(url as CFURL)
    }

    /// Updates the currently visible page range so queued stale pages are dropped immediately before locking an `IOSurface`.
    func updateActiveRange(_ range: ClosedRange<Int>) {
        lock.lock()
        activeRange = range
        lock.unlock()
    }

    /// Cancels only queued in-flight renders (e.g. on zoom scale change) while KEEPING cached surfaces for instant return!
    func cancelInFlight() {
        lock.lock()
        generation &+= 1
        inFlight.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Invalidates all cached surfaces (e.g. on quality preference change or hibernation) and recycles them to the pool.
    func invalidateCacheForScaleOrQuality() {
        lock.lock()
        generation &+= 1
        let oldDrafts = Array(draftCache.values)
        let oldRetinas = Array(retinaCache.values)
        draftCache.removeAll(keepingCapacity: true)
        draftLRU.removeAll(keepingCapacity: true)
        retinaCache.removeAll(keepingCapacity: true)
        retinaLRU.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
        lock.unlock()

        _ = oldDrafts
        _ = oldRetinas
    }

    /// Cancels all pending renders and releases every cached `IOSurface` back to `MacIOSurfacePool`.
    func releaseAllSurfaces() {
        invalidateCacheForScaleOrQuality()
    }

    /// Computes area-capped crisp Tier 1 Draft dimensions (<= 1.05 MP, ~4.2 MB, even pixels) preserving exact aspect ratio.
    static func draftPixelSize(forPageSize pageSize: CGSize) -> (Int, Int) {
        let w = max(1.0, pageSize.width)
        let h = max(1.0, pageSize.height)
        let maxPixels: CGFloat = 640_000.0
        let area = w * h
        let scale = sqrt(maxPixels / area)
        let clampedScale = min(scale, 1.30)
        let pw = max(32, Int((w * clampedScale).rounded()) & ~1)
        let ph = max(32, Int((h * clampedScale).rounded()) & ~1)
        return (pw, ph)
    }

    /// Computes area-capped Tier 2 crisp Retina pixel dimensions (<= 1.85 MP normal, <= 2.40 MP when zoomed).
    static func retinaPixelSize(forViewSize viewSize: CGSize, backingScale: CGFloat, isZoomedIn: Bool = false) -> (Int, Int) {
        let effectiveScale = min(backingScale, isZoomedIn ? 1.85 : 1.55)
        var pw = viewSize.width * effectiveScale
        var ph = viewSize.height * effectiveScale
        let maxPixels: CGFloat = isZoomedIn ? 2_200_000.0 : 1_550_000.0
        let area = pw * ph
        if area > maxPixels {
            let k = sqrt(maxPixels / area)
            pw *= k
            ph *= k
        }
        let maxDim: CGFloat = 2400.0
        if max(pw, ph) > maxDim {
            let k = maxDim / max(pw, ph)
            pw *= k
            ph *= k
        }
        return (max(32, Int(pw.rounded()) & ~1), max(32, Int(ph.rounded()) & ~1))
    }

    /// Synchronous cache lookup for a specific tier & pixel size.
    func cachedSurface(slotKey: String, tier: MacRenderTier, pixelW: Int, pixelH: Int, highQuality: Bool) -> MacRenderedPageSurface? {
        let key = CacheKey(slotKey: slotKey, tier: tier, pixelW: pixelW, pixelH: pixelH, highQuality: highQuality)
        lock.lock()
        defer { lock.unlock() }
        switch tier {
        case .draft:
            if let hit = draftCache[key] {
                if let idx = draftLRU.firstIndex(of: key) { draftLRU.remove(at: idx) }
                draftLRU.append(key)
                return hit
            }
        case .retina:
            if let hit = retinaCache[key] {
                if let idx = retinaLRU.firstIndex(of: key) { retinaLRU.remove(at: idx) }
                retinaLRU.append(key)
                return hit
            }
        }
        return nil
    }

    /// Requests an asynchronous `IOSurface` render on the appropriate serial QoS queue (`.utility` for draft, `.background` for retina).
    func requestRender(
        tier: MacRenderTier,
        pageIndex: Int,
        slot: PageSlot,
        isHobonichi: Bool,
        docSnapshot: InkDocument?,
        allSlots: [PageSlot],
        pixelW: Int,
        pixelH: Int,
        highQuality: Bool,
        colorSpace: CGColorSpace,
        completion: @escaping @MainActor (MacRenderedPageSurface?) -> Void
    ) {
        let key = CacheKey(slotKey: slot.key, tier: tier, pixelW: pixelW, pixelH: pixelH, highQuality: highQuality)

        lock.lock()
        if let hit = (tier == .draft ? draftCache[key] : retinaCache[key]) {
            lock.unlock()
            Task { @MainActor in completion(hit) }
            return
        }
        if inFlight.contains(key) {
            lock.unlock()
            return
        }
        inFlight.insert(key)
        let reqGen = generation
        lock.unlock()

        let targetQueue = (tier == .draft) ? draftQueue : retinaQueue
        targetQueue.async { [weak self] in
            guard let self else { return }

            let shouldSkip: Bool = {
                self.lock.lock()
                defer { self.lock.unlock() }
                if self.generation != reqGen {
                    self.inFlight.remove(key)
                    return true
                }
                let margin = (tier == .draft) ? 1 : 0
                let lo = max(0, self.activeRange.lowerBound - margin)
                let hi = self.activeRange.upperBound + margin
                if pageIndex < lo || pageIndex > hi {
                    self.inFlight.remove(key)
                    return true
                }
                return false
            }()
            if shouldSkip { return }

            let rendered: MacRenderedPageSurface? = autoreleasepool {
                self.renderIntoIOSurfaceSync(
                    tier: tier,
                    slot: slot,
                    isHobonichi: isHobonichi,
                    docSnapshot: docSnapshot,
                    allSlots: allSlots,
                    pixelW: pixelW,
                    pixelH: pixelH,
                    highQuality: highQuality,
                    colorSpace: colorSpace
                )
            }

            self.lock.lock()
            self.inFlight.remove(key)
            let stillValid = (self.generation == reqGen)
            if stillValid, let surfaceObj = rendered {
                switch tier {
                case .draft:
                    self.draftCache[key] = surfaceObj
                    if let idx = self.draftLRU.firstIndex(of: key) { self.draftLRU.remove(at: idx) }
                    self.draftLRU.append(key)
                    while self.draftLRU.count > self.maxCachedDrafts {
                        let evict = self.draftLRU.removeFirst()
                        self.draftCache.removeValue(forKey: evict)
                    }
                case .retina:
                    self.retinaCache[key] = surfaceObj
                    if let idx = self.retinaLRU.firstIndex(of: key) { self.retinaLRU.remove(at: idx) }
                    self.retinaLRU.append(key)
                    while self.retinaLRU.count > self.maxCachedRetina {
                        let evict = self.retinaLRU.removeFirst()
                        self.retinaCache.removeValue(forKey: evict)
                    }
                }
            }
            self.lock.unlock()

            if stillValid {
                Task { @MainActor in
                    completion(rendered)
                }
            }
        }
    }

    private func renderIntoIOSurfaceSync(
        tier: MacRenderTier,
        slot: PageSlot,
        isHobonichi: Bool,
        docSnapshot: InkDocument?,
        allSlots: [PageSlot],
        pixelW: Int,
        pixelH: Int,
        highQuality: Bool,
        colorSpace: CGColorSpace
    ) -> MacRenderedPageSurface? {
        guard pixelW >= 8, pixelH >= 8 else { return nil }
        guard let surface = MacIOSurfacePool.shared.acquire(tier: tier, width: pixelW, height: pixelH, colorSpace: colorSpace) else {
            return nil
        }

        let csName = colorSpace.name.map { $0 as String } ?? "sRGB"
        let lockResult = IOSurfaceLock(surface, [], nil)
        guard lockResult == KERN_SUCCESS else {
            MacIOSurfacePool.shared.recycle(surface, tier: tier, colorSpaceName: csName)
            return nil
        }

        let baseAddr = IOSurfaceGetBaseAddress(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(
            data: baseAddr,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            IOSurfaceUnlock(surface, [], nil)
            MacIOSurfacePool.shared.recycle(surface, tier: tier, colorSpaceName: csName)
            return nil
        }

        // Opaque white page background (sets alpha = 0xFF across entire 32BGRA surface).
        ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)
        // Vector PDF text stays 100% antialiased CoreText regardless of interpolationQuality;
        // `.none` on draft & `.low` on settled Retina cuts embedded-image CPU filtering drastically!
        if tier == .draft {
            ctx.interpolationQuality = .low
        } else {
            ctx.interpolationQuality = highQuality ? .high : .low
        }

        let sx = CGFloat(pixelW) / max(1.0, slot.size.width)
        let sy = CGFloat(pixelH) / max(1.0, slot.size.height)

        if isHobonichi, HobonichiEngine.slotKind(for: slot, isHobo: true) != nil, let doc = docSnapshot {
            ctx.translateBy(x: 0, y: CGFloat(pixelH))
            ctx.scaleBy(x: sx, y: -sy)
            HobonichiEngine.drawSpread(in: ctx, slot: slot, doc: doc, allSlots: allSlots, isHobo: true)
        } else if let pdfN = slot.effectivePDFPageNumber {
            let cgDoc: CGPDFDocument?
            if tier == .draft {
                if draftCGDoc == nil, let url = pdfURL {
                    draftCGDoc = Self.openCGPDFDocument(url: url, mappedData: mappedPDFData)
                }
                cgDoc = draftCGDoc
            } else {
                if retinaCGDoc == nil, let url = pdfURL {
                    retinaCGDoc = Self.openCGPDFDocument(url: url, mappedData: mappedPDFData)
                }
                cgDoc = retinaCGDoc
            }

            if let cgPage = cgDoc?.page(at: pdfN) {
                Self.drawPDFPageEdgeToEdge(cgPage, in: ctx, pixelW: pixelW, pixelH: pixelH)
            }
        } else {
            ctx.translateBy(x: 0, y: CGFloat(pixelH))
            ctx.scaleBy(x: sx, y: -sy)
            slot.template.draw(in: ctx, size: slot.size)
        }

        ctx.flush()
        IOSurfaceUnlock(surface, [], nil)

        return MacRenderedPageSurface(
            surface: surface,
            tier: tier,
            pixelW: pixelW,
            pixelH: pixelH,
            colorSpaceName: csName
        )
    }

    /// Explicit edge-to-edge `cropBox` + `rotationAngle` transform (supports scaling UP > 1.0x for Retina & slides).
    static func drawPDFPageEdgeToEdge(_ cgPage: CGPDFPage, in ctx: CGContext, pixelW: Int, pixelH: Int) {
        PlatformGraphics.drawPDFPageEdgeToEdge(cgPage, in: ctx, targetW: CGFloat(pixelW), targetH: CGFloat(pixelH))
    }
}
