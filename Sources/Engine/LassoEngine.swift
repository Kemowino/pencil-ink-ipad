import Foundation
import CoreGraphics

enum LassoInteractionMode {
    case none
    case drawing
    case dragging
    case scaling
    case rotating
}

struct LassoHandleGeometry {
    let bx0: CGFloat
    let by0: CGFloat
    let bx1: CGFloat
    let by1: CGFloat
    let cx: CGFloat
    let cy: CGFloat
    let rotY: CGFloat
    let corners: [(id: String, x: CGFloat, y: CGFloat, ax: CGFloat, ay: CGFloat)]
}

struct LassoClipboard {
    let center: CGPoint
    let width: CGFloat
    let height: CGFloat
    let strokes: [InkStroke]
}

struct LassoSelection {
    var mode: LassoInteractionMode = .none
    var pageKey: String
    var poly: [CGPoint] = []
    var strokes: [InkStroke] = []
    var origBox: CGRect = .zero
    var box: CGRect = .zero
    var tx: CGFloat = 0
    var ty: CGFloat = 0
    var scale: CGFloat = 1.0
    var rotation: CGFloat = 0.0
    var pivot: CGPoint = .zero
    var startPoint: CGPoint = .zero
    var startDistX: CGFloat = 1.0
    var startDistY: CGFloat = 1.0
    var startAngle: CGFloat = 0.0

    var hiddenStrokeIDs: Set<String> {
        Set(strokes.map { $0.id })
    }

    var hasTransform: Bool {
        hypot(tx, ty) > 0.25 || abs(scale - 1.0) > 0.005 || abs(rotation) > 0.005
    }

    func handles(zoomScale: CGFloat) -> LassoHandleGeometry {
        let sc = max(0.5, zoomScale)
        let pad = 6.0 / sc
        let bx0 = box.minX - pad
        let by0 = box.minY - pad
        let bx1 = box.maxX + pad
        let by1 = box.maxY + pad
        let cx = (bx0 + bx1) * 0.5
        let cy = (by0 + by1) * 0.5
        let rotY = by0 - 20.0 / sc
        return LassoHandleGeometry(
            bx0: bx0, by0: by0, bx1: bx1, by1: by1,
            cx: cx, cy: cy, rotY: rotY,
            corners: [
                ("nw", bx0, by0, bx1, by1),
                ("ne", bx1, by0, bx0, by1),
                ("se", bx1, by1, bx0, by0),
                ("sw", bx0, by1, bx1, by0)
            ]
        )
    }
}

enum LassoMath {
    static func pointInPolygon(_ pt: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].x, yi = polygon[i].y
            let xj = polygon[j].x, yj = polygon[j].y
            let intersect = ((yi > pt.y) != (yj > pt.y)) &&
                (pt.x < (xj - xi) * (pt.y - yi) / ((yj - yi) != 0 ? (yj - yi) : 1e-9) + xi)
            if intersect { inside.toggle() }
            j = i
        }
        return inside
    }

    static func selectStrokes(in strokes: [InkStroke], polygon: [CGPoint]) -> (selected: [InkStroke], box: CGRect) {
        var selected: [InkStroke] = []
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for s in strokes {
            let n = s.pointCount
            guard n > 0 else { continue }
            var hits = 0
            var total = 0
            let step = max(1, n / 24)
            var i = 0
            while i < n {
                total += 1
                let pt = CGPoint(x: CGFloat(s.pts[i * 3]), y: CGFloat(s.pts[i * 3 + 1]))
                if pointInPolygon(pt, polygon: polygon) { hits += 1 }
                i += step
            }
            let b = s.boundingBox()
            let centerInside = pointInPolygon(CGPoint(x: b.midX, y: b.midY), polygon: polygon)
            if (total > 0 && Double(hits) / Double(total) >= 0.25) || centerInside {
                selected.append(s)
                if b.minX < minX { minX = b.minX }
                if b.minY < minY { minY = b.minY }
                if b.maxX > maxX { maxX = b.maxX }
                if b.maxY > maxY { maxY = b.maxY }
            }
        }
        guard !selected.isEmpty else { return ([], .zero) }
        return (selected, CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY)))
    }

    static func transformedStroke(
        _ s: InkStroke,
        pivot: CGPoint,
        tx: CGFloat,
        ty: CGFloat,
        scale: CGFloat,
        rotation: CGFloat
    ) -> InkStroke {
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let n = s.pointCount
        var newPts: [Double] = []
        newPts.reserveCapacity(s.pts.count)
        for i in 0..<n {
            var px = (CGFloat(s.pts[i * 3]) - pivot.x) * scale
            var py = (CGFloat(s.pts[i * 3 + 1]) - pivot.y) * scale
            if rotation != 0 {
                let rx = px * cosR - py * sinR
                let ry = px * sinR + py * cosR
                px = rx
                py = ry
            }
            let fx = (Double(pivot.x + px + tx) * 100.0).rounded() / 100.0
            let fy = (Double(pivot.y + py + ty) * 100.0).rounded() / 100.0
            newPts.append(fx)
            newPts.append(fy)
            newPts.append(s.pts[i * 3 + 2])
        }
        var copy = s
        copy.id = InkStroke.newID()
        copy.t = Int64(Date().timeIntervalSince1970 * 1000)
        copy.size = max(0.4, min(80.0, (s.size * Double(abs(scale)) * 100.0).rounded() / 100.0))
        copy.pts = newPts
        return copy
    }

    static func translatedCopy(_ s: InkStroke, dx: CGFloat, dy: CGFloat) -> InkStroke {
        let n = s.pointCount
        var newPts: [Double] = []
        newPts.reserveCapacity(s.pts.count)
        for i in 0..<n {
            let fx = (Double(CGFloat(s.pts[i * 3]) + dx) * 100.0).rounded() / 100.0
            let fy = (Double(CGFloat(s.pts[i * 3 + 1]) + dy) * 100.0).rounded() / 100.0
            newPts.append(fx)
            newPts.append(fy)
            newPts.append(s.pts[i * 3 + 2])
        }
        var copy = s
        copy.id = InkStroke.newID()
        copy.t = Int64(Date().timeIntervalSince1970 * 1000)
        copy.pts = newPts
        return copy
    }

    static func combinedBox(of strokes: [InkStroke]) -> CGRect {
        guard !strokes.isEmpty else { return .zero }
        var r = strokes[0].boundingBox()
        for s in strokes.dropFirst() {
            r = r.union(s.boundingBox())
        }
        return r
    }
}
