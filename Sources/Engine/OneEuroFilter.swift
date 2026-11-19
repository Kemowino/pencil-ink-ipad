import Foundation
import CoreGraphics

/// Same 1-Euro velocity-adaptive smoothing filter used by Pencil Ink,
/// giving crisp handwriting with zero wobble and ultra-low latency.
final class OneEuroSmoother {
    private let minCut: Double
    private let beta: Double
    private let scale: Double
    private var sx: Double = 0
    private var sy: Double = 0
    private var dx: Double = 0
    private var dy: Double = 0
    private var lastT: Double = 0
    private var initialized = false

    init(scale: CGFloat, minCut: Double = 4.5, beta: Double = 0.03) {
        self.scale = max(0.5, Double(scale))
        self.minCut = minCut
        self.beta = beta
    }

    private func alpha(cutHz: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutHz)
        return 1.0 / (1.0 + tau / dt)
    }

    func filter(_ pt: InkPoint) -> InkPoint {
        let x = Double(pt.x) * scale
        let y = Double(pt.y) * scale
        let t = pt.t
        if !initialized {
            initialized = true
            sx = x
            sy = y
            dx = 0
            dy = 0
            lastT = t
            return pt
        }
        let dt = max(t - lastT, 0.001)
        let ad = alpha(cutHz: 1.0, dt: dt)
        dx = ad * ((x - sx) / dt) + (1.0 - ad) * dx
        dy = ad * ((y - sy) / dt) + (1.0 - ad) * dy
        let speed = hypot(dx, dy)
        let a = alpha(cutHz: minCut + beta * speed, dt: dt)
        sx = a * x + (1.0 - a) * sx
        sy = a * y + (1.0 - a) * sy
        lastT = t
        return InkPoint(x: CGFloat(sx / scale), y: CGFloat(sy / scale), p: pt.p, t: pt.t)
    }
}

enum StrokeGeometry {
    static func buildSmoothPath(from flatPts: [Double]) -> CGPath {
        let path = CGMutablePath()
        let n = flatPts.count / 3
        guard n > 0 else { return path }
        let x0 = CGFloat(flatPts[0])
        let y0 = CGFloat(flatPts[1])
        path.move(to: CGPoint(x: x0, y: y0))
        if n == 1 {
            path.addLine(to: CGPoint(x: x0 + 0.05, y: y0))
            return path
        }
        if n == 2 {
            path.addLine(to: CGPoint(x: CGFloat(flatPts[3]), y: CGFloat(flatPts[4])))
            return path
        }
        let m0 = CGPoint(
            x: (x0 + CGFloat(flatPts[3])) * 0.5,
            y: (y0 + CGFloat(flatPts[4])) * 0.5
        )
        path.addLine(to: m0)
        for i in 1..<(n - 1) {
            let cx = CGFloat(flatPts[i * 3])
            let cy = CGFloat(flatPts[i * 3 + 1])
            let nx = CGFloat(flatPts[(i + 1) * 3])
            let ny = CGFloat(flatPts[(i + 1) * 3 + 1])
            let mid = CGPoint(x: (cx + nx) * 0.5, y: (cy + ny) * 0.5)
            path.addQuadCurve(to: mid, control: CGPoint(x: cx, y: cy))
        }
        path.addLine(to: CGPoint(x: CGFloat(flatPts[(n - 1) * 3]), y: CGFloat(flatPts[(n - 1) * 3 + 1])))
        return path
    }

    static func buildSmoothPath(from pts: [InkPoint]) -> CGPath {
        let path = CGMutablePath()
        let n = pts.count
        guard n > 0 else { return path }
        path.move(to: CGPoint(x: pts[0].x, y: pts[0].y))
        if n == 1 {
            path.addLine(to: CGPoint(x: pts[0].x + 0.05, y: pts[0].y))
            return path
        }
        if n == 2 {
            path.addLine(to: CGPoint(x: pts[1].x, y: pts[1].y))
            return path
        }
        let m0 = CGPoint(x: (pts[0].x + pts[1].x) * 0.5, y: (pts[0].y + pts[1].y) * 0.5)
        path.addLine(to: m0)
        for i in 1..<(n - 1) {
            let cur = pts[i]
            let nxt = pts[i + 1]
            let mid = CGPoint(x: (cur.x + nxt.x) * 0.5, y: (cur.y + nxt.y) * 0.5)
            path.addQuadCurve(to: mid, control: CGPoint(x: cur.x, y: cur.y))
        }
        path.addLine(to: CGPoint(x: pts[n - 1].x, y: pts[n - 1].y))
        return path
    }

    static func strokeHits(_ stroke: InkStroke, point: CGPoint, radius: CGFloat) -> Bool {
        let r = radius + CGFloat(stroke.size) * 0.5
        let box = stroke.boundingBox().insetBy(dx: -r, dy: -r)
        guard box.contains(point) else { return false }
        let n = stroke.pointCount
        let r2 = r * r
        if n == 1 {
            let dx = point.x - CGFloat(stroke.pts[0])
            let dy = point.y - CGFloat(stroke.pts[1])
            return dx * dx + dy * dy <= r2
        }
        for i in 1..<n {
            let ax = CGFloat(stroke.pts[(i - 1) * 3])
            let ay = CGFloat(stroke.pts[(i - 1) * 3 + 1])
            let bx = CGFloat(stroke.pts[i * 3])
            let by = CGFloat(stroke.pts[i * 3 + 1])
            if segDistSq(px: point.x, py: point.y, ax: ax, ay: ay, bx: bx, by: by) <= r2 {
                return true
            }
        }
        return false
    }

    private static func segDistSq(px: CGFloat, py: CGFloat, ax: CGFloat, ay: CGFloat, bx: CGFloat, by: CGFloat) -> CGFloat {
        let dx = bx - ax
        let dy = by - ay
        let l2 = dx * dx + dy * dy
        let t = l2 > 0 ? max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) : 0
        let ex = px - (ax + t * dx)
        let ey = py - (ay + t * dy)
        return ex * ex + ey * ey
    }
}
