import AppKit
import CoreGraphics
import Foundation
import IOSurface
import QuartzCore

/// Render resolution tier for two-tier progressive PDF rasterization.
enum MacRenderTier: Int, Hashable {
    /// Tier 1: Area-capped crisp draft (<= 0.68 MP, ~2.7 MB, ~2-3 ms on Intel with `.none` image interp) used during active scrolling.
    case draft = 1
    /// Tier 2: Area-capped Retina (<= 1.75 MP normal / 2.35 MP zoomed) rendered at `.background` QoS ONLY after scrolling truly stops.
    case retina = 2
}

/// Thread-safe, hardware-aligned FIFO `IOSurface` ring-buffer pool shared across all tabs.
///
/// v4.1.0 Anti-Ghosting Upgrade:
/// - **FIFO acquisition (`firstIndex`) + 150 ms WindowServer cool-down:** Never hands back a just-detached
///   surface while `WindowServer` may still be scanning it out, eliminating scrolling ghosting/tearing completely.
/// - Zero `vm_allocate` / zero-fill `vm_fault` kernel `Sys` CPU churn during scrolling.
/// - Zero Main-Thread `CARenderImageCopy` + ColorSync conversion (`layer.contents = surface`).
final class MacIOSurfacePool {
    static let shared = MacIOSurfacePool()

    /// Snapshot of pool health & reuse efficiency for the Self-Test report.
    struct Stats {
        let totalAllocations: UInt64
        let poolHits: UInt64
        let poolMisses: UInt64
        let pooledDraftCount: Int
        let pooledRetinaCount: Int
        let estimatedPooledBytes: UInt64

        var hitRatePercent: Double {
            let total = poolHits + poolMisses
            guard total > 0 else { return 100.0 }
            return (Double(poolHits) / Double(total)) * 100.0
        }
    }

    private struct SurfaceKey: Hashable {
        let width: Int
        let height: Int
        let colorSpaceName: String
    }

    private struct PooledEntry {
        let key: SurfaceKey
        let surface: IOSurfaceRef
        let byteSize: UInt64
        let recycledAt: CFTimeInterval
    }

    private let lock = NSLock()
    private var draftPool: [PooledEntry] = []
    private var retinaPool: [PooledEntry] = []

    /// Balanced memory caps (~36 MB drafts + ~36 MB retina = ~72 MB hard ceiling).
    private let maxDraftSurfaces = 18
    private let maxRetinaSurfaces = 6

    /// Minimum cool-down after detaching from a `CALayer` before the same `IOSurface` can be rewritten.
    private let reuseCooldownSec: CFTimeInterval = 0.15

    private var totalAllocations: UInt64 = 0
    private var poolHits: UInt64 = 0
    private var poolMisses: UInt64 = 0

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.purgeAll()
        }
        source.resume()
        self.memoryPressureSource = source
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    /// Resolves the best display-native `CGColorSpace` for a window/screen so `WindowServer` skips ColorSync matching.
    static func preferredDisplayColorSpace(for screen: NSScreen? = NSScreen.main) -> CGColorSpace {
        if let cs = screen?.colorSpace?.cgColorSpace, cs.model == .rgb {
            return cs
        }
        return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Acquires a reusable, 64-byte-aligned `32BGRA` `IOSurface` matching `(width, height, colorSpace)`
    /// using strict FIFO ordering + cool-down + `!IOSurfaceIsInUse` to guarantee zero tearing/ghosting.
    func acquire(tier: MacRenderTier, width: Int, height: Int, colorSpace: CGColorSpace) -> IOSurfaceRef? {
        guard width >= 8, height >= 8 else { return nil }
        let csName = colorSpace.name.map { $0 as String } ?? "sRGB"
        let key = SurfaceKey(width: width, height: height, colorSpaceName: csName)
        let now = CACurrentMediaTime()

        lock.lock()
        switch tier {
        case .draft:
            if let idx = draftPool.firstIndex(where: {
                $0.key == key && (now - $0.recycledAt) >= reuseCooldownSec && !IOSurfaceIsInUse($0.surface)
            }) {
                let entry = draftPool.remove(at: idx)
                poolHits &+= 1
                lock.unlock()
                return entry.surface
            }
        case .retina:
            if let idx = retinaPool.firstIndex(where: {
                $0.key == key && (now - $0.recycledAt) >= reuseCooldownSec && !IOSurfaceIsInUse($0.surface)
            }) {
                let entry = retinaPool.remove(at: idx)
                poolHits &+= 1
                lock.unlock()
                return entry.surface
            }
        }
        poolMisses &+= 1
        lock.unlock()

        // Allocate a fresh hardware-aligned 32BGRA IOSurface tagged with the display's native colorspace.
        let bytesPerElement = 4
        let rawBPR = width * bytesPerElement
        let aligned = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, rawBPR)
        let bytesPerRow = max(rawBPR, aligned > 0 ? aligned : ((rawBPR + 63) & ~63))
        let allocSize = bytesPerRow * height
        let pixelFormat: UInt32 = 0x42475241 // 'BGRA' (kCVPixelFormatType_32BGRA)

        let props: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: bytesPerElement,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfaceAllocSize: allocSize,
            kIOSurfacePixelFormat: pixelFormat
        ]

        guard let surface = IOSurfaceCreate(props as CFDictionary) else { return nil }
        if let cfName = colorSpace.name {
            IOSurfaceSetValue(surface, "IOSurfaceColorSpace" as CFString, cfName)
        }

        lock.lock()
        totalAllocations &+= 1
        lock.unlock()
        return surface
    }

    /// Returns a previously acquired `IOSurface` to the tail of the FIFO ring buffer with a cool-down timestamp.
    func recycle(_ surface: IOSurfaceRef, tier: MacRenderTier, colorSpaceName: String) {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bpr = IOSurfaceGetBytesPerRow(surface)
        let entry = PooledEntry(
            key: SurfaceKey(width: width, height: height, colorSpaceName: colorSpaceName),
            surface: surface,
            byteSize: UInt64(bpr * height),
            recycledAt: CACurrentMediaTime()
        )

        lock.lock()
        switch tier {
        case .draft:
            draftPool.append(entry)
            while draftPool.count > maxDraftSurfaces {
                draftPool.removeFirst()
            }
        case .retina:
            retinaPool.append(entry)
            while retinaPool.count > maxRetinaSurfaces {
                retinaPool.removeFirst()
            }
        }
        lock.unlock()
    }

    /// Releases all idle pooled surfaces immediately (called on macOS memory pressure or explicit trim).
    func purgeAll() {
        lock.lock()
        draftPool.removeAll(keepingCapacity: false)
        retinaPool.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        let draftBytes = draftPool.reduce(UInt64(0)) { $0 + $1.byteSize }
        let retinaBytes = retinaPool.reduce(UInt64(0)) { $0 + $1.byteSize }
        return Stats(
            totalAllocations: totalAllocations,
            poolHits: poolHits,
            poolMisses: poolMisses,
            pooledDraftCount: draftPool.count,
            pooledRetinaCount: retinaPool.count,
            estimatedPooledBytes: draftBytes + retinaBytes
        )
    }

    func resetCounters() {
        lock.lock()
        totalAllocations = 0
        poolHits = 0
        poolMisses = 0
        lock.unlock()
    }
}
