import Foundation
import CoreGraphics
import PDFKit

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformImage = NSImage

extension NSFont {
    /// Matches `UIFont.lineHeight` so `InkTextBox.measuredRect()` produces identical dimensions on macOS & iPadOS.
    var lineHeight: CGFloat {
        ceil(ascender - descender + leading)
    }
}

extension NSImage {
    /// Matches `UIImage.jpegData(compressionQuality:)` for shared persistent cover thumbnail caching.
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
#endif

enum PlatformGraphics {
    static let sharedSRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Pushes a top-left-origin CoreGraphics context for `NSString.draw(in:withAttributes:)` on both UIKit & AppKit.
    static func pushFlippedContext(_ ctx: CGContext) {
        #if canImport(UIKit)
        UIGraphicsPushContext(ctx)
        #elseif canImport(AppKit)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        #endif
    }

    static func popFlippedContext() {
        #if canImport(UIKit)
        UIGraphicsPopContext()
        #elseif canImport(AppKit)
        NSGraphicsContext.restoreGraphicsState()
        #endif
    }

    /// Pure CoreGraphics multi-page PDF generator (works identically on iOS & macOS, zero UIKit dependency).
    static func makePDFData(pageSizes: [CGSize], drawPage: (Int, CGContext, CGRect) -> Void) -> Data {
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else { return Data() }
        var defaultBox = CGRect(origin: .zero, size: pageSizes.first ?? CGSize(width: 595, height: 842))
        guard let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else { return Data() }
        for (idx, sz) in pageSizes.enumerated() {
            var box = CGRect(origin: .zero, size: sz)
            let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
            let pageInfo = [kCGPDFContextMediaBox as String: boxData] as CFDictionary
            ctx.beginPDFPage(pageInfo)
            ctx.saveGState()
            // Flip into top-left coordinates matching PaperTemplate & HobonichiEngine drawing
            ctx.translateBy(x: 0, y: sz.height)
            ctx.scaleBy(x: 1, y: -1)
            drawPage(idx, ctx, CGRect(origin: .zero, size: sz))
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    static func normalizedPageSize(for cgPage: CGPDFPage) -> CGSize {
        let box = cgPage.getBoxRect(.cropBox)
        let rot = ((Int(cgPage.rotationAngle) % 360) + 360) % 360
        if rot == 90 || rot == 270 {
            return CGSize(width: box.height, height: box.width)
        }
        return box.size
    }

    static func normalizedPageSize(for page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        let rot = ((page.rotation % 360) + 360) % 360
        if rot == 90 || rot == 270 {
            return CGSize(width: box.height, height: box.width)
        }
        return box.size
    }

    /// Explicit edge-to-edge `cropBox` + `rotationAngle` PDF page transform (supports scaling UP > 1.0x).
    /// Assumes a standard bottom-left CoreGraphics coordinate system covering `(0, 0, targetW, targetH)`.
    static func drawPDFPageEdgeToEdge(_ cgPage: CGPDFPage, in ctx: CGContext, targetW: CGFloat, targetH: CGFloat) {
        let crop = cgPage.getBoxRect(.cropBox)
        guard crop.width > 0.1, crop.height > 0.1, targetW > 0.1, targetH > 0.1 else { return }

        let rotCW = ((Int(cgPage.rotationAngle) % 360) + 360) % 360
        let isSideways = (rotCW == 90 || rotCW == 270)
        let effW = isSideways ? crop.height : crop.width
        let effH = isSideways ? crop.width : crop.height

        let scale = min(targetW / effW, targetH / effH)

        ctx.saveGState()
        ctx.translateBy(x: targetW * 0.5, y: targetH * 0.5)
        ctx.scaleBy(x: scale, y: scale)
        if rotCW != 0 {
            ctx.rotate(by: -CGFloat(rotCW) * (.pi / 180.0))
        }
        ctx.translateBy(x: -(crop.minX + crop.width * 0.5), y: -(crop.minY + crop.height * 0.5))
        ctx.clip(to: crop)
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()
    }

    /// Renders a compact cover preview thumbnail of page 1 directly via CoreGraphics (shared by iOS & macOS VaultManager).
    static func renderPDFCoverImage(cgPage: CGPDFPage, pageSize: CGSize, targetWidth: CGFloat = 240.0, maxPixels: CGFloat = 240_000) -> PlatformImage? {
        autoreleasepool {
            guard pageSize.width > 1, pageSize.height > 1 else { return nil }
            let desiredScale = max(0.25, min(1.5, (targetWidth * 1.5) / pageSize.width))
            let rawPx = (pageSize.width * desiredScale) * (pageSize.height * desiredScale)
            let finalScale = rawPx > maxPixels ? desiredScale * sqrt(maxPixels / rawPx) : desiredScale
            let pxW = max(1, Int((pageSize.width * finalScale).rounded()))
            let pxH = max(1, Int((pageSize.height * finalScale).rounded()))
            let bpr = ((pxW * 4 + 63) / 64) * 64
            let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            guard let ctx = CGContext(
                data: nil,
                width: pxW,
                height: pxH,
                bitsPerComponent: 8,
                bytesPerRow: bpr,
                space: sharedSRGB,
                bitmapInfo: info
            ) else { return nil }

            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
            ctx.setShouldAntialias(true)
            ctx.interpolationQuality = .low
            drawPDFPageEdgeToEdge(cgPage, in: ctx, targetW: CGFloat(pxW), targetH: CGFloat(pxH))

            guard let cgImg = ctx.makeImage() else { return nil }
            #if canImport(UIKit)
            return UIImage(cgImage: cgImg)
            #elseif canImport(AppKit)
            return NSImage(cgImage: cgImg, size: NSSize(width: pageSize.width, height: pageSize.height))
            #endif
        }
    }
}
