import Foundation
import CoreGraphics
import UIKit

/// Stabilization levels 0..5 matching Obsidian Pencil Ink's exact 1-Euro parameters.
final class OneEuroSmoother {
    private let level: Int
    private let minCut: Double
    private let beta: Double
    private let scale: Double
    private var sx: Double = 0
    private var sy: Double = 0
    private var dx: Double = 0
    private var dy: Double = 0
    private var lastT: Double = 0
    private var initialized = false

    static func params(for level: Int) -> (minCut: Double, beta: Double)? {
        switch level {
        case 1: return (11.0, 0.14)
        case 2: return (8.0, 0.08)
        case 3: return (4.5, 0.03)
        case 4: return (3.4, 0.02)
        case 5: return (2.6, 0.012)
        default: return nil
        }
    }

    init(scale: CGFloat, level: Int = 3) {
        self.level = max(0, min(5, level))
        self.scale = max(0.5, Double(scale))
        if let p = OneEuroSmoother.params(for: self.level) {
            self.minCut = p.minCut
            self.beta = p.beta
        } else {
            self.minCut = 4.5
            self.beta = 0.03
        }
    }

    private func alpha(cutHz: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutHz)
        return 1.0 / (1.0 + tau / dt)
    }

    func filter(_ pt: InkPoint) -> InkPoint {
        if level == 0 { return pt }
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
    static func pointWidth(pressure rawP: CGFloat, baseSize: CGFloat, style: String, sensitivity: Double = 1.0) -> CGFloat {
        if style == "ball" { return baseSize }
        let clamped = max(0.05, min(1.0, rawP))
        let sens = max(0.25, sensitivity)
        let p = CGFloat(pow(Double(clamped), 1.0 / sens))
        if style == "brush" {
            return baseSize * (0.35 + 1.30 * p)
        }
        // "fountain"
        return baseSize * (0.55 + 0.90 * p)
    }

    static func buildLinearPath(from pts: [InkPoint]) -> CGPath {
        let path = CGMutablePath()
        guard !pts.isEmpty else { return path }
        path.move(to: CGPoint(x: pts[0].x, y: pts[0].y))
        if pts.count == 1 {
            path.addLine(to: CGPoint(x: pts[0].x + 0.05, y: pts[0].y))
            return path
        }
        for i in 1..<pts.count {
            path.addLine(to: CGPoint(x: pts[i].x, y: pts[i].y))
        }
        return path
    }

    static func buildLinearPath(from flatPts: [Double]) -> CGPath {
        let path = CGMutablePath()
        let n = flatPts.count / 3
        guard n > 0 else { return path }
        path.move(to: CGPoint(x: CGFloat(flatPts[0]), y: CGFloat(flatPts[1])))
        if n == 1 {
            path.addLine(to: CGPoint(x: CGFloat(flatPts[0]) + 0.05, y: CGFloat(flatPts[1])))
            return path
        }
        for i in 1..<n {
            path.addLine(to: CGPoint(x: CGFloat(flatPts[i * 3]), y: CGFloat(flatPts[i * 3 + 1])))
        }
        return path
    }

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

    /// Renders either uniform ("ball" / highlighter / straight shapes) or variable-width ("fountain" / "brush") stroke in CoreGraphics.
    static func drawStroke(
        in ctx: CGContext,
        points pts: [InkPoint],
        color: UIColor,
        baseSize: CGFloat,
        tool: String,
        style: String,
        straight: Bool,
        isSmartShape: Bool,
        sensitivity: Double = 1.0
    ) {
        let n = pts.count
        guard n > 0 else { return }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)

        let effectiveStyle = (tool == "highlighter" || straight || isSmartShape) ? "ball" : style
        if n == 1 {
            let w0 = pointWidth(pressure: pts[0].p, baseSize: baseSize, style: effectiveStyle, sensitivity: sensitivity)
            let r = w0 * 0.5 * 1.2
            ctx.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: r * 2, height: r * 2))
            return
        }

        if effectiveStyle == "ball" {
            ctx.setLineWidth(baseSize)
            let path = straight ? buildLinearPath(from: pts) : buildSmoothPath(from: pts)
            ctx.addPath(path)
            ctx.strokePath()
            return
        }

        // Check if pressure is completely flat (e.g. imported constant-pressure stroke)
        var pMin: CGFloat = 1.0
        var pMax: CGFloat = 0.0
        for pt in pts {
            if pt.p < pMin { pMin = pt.p }
            if pt.p > pMax { pMax = pt.p }
        }
        if pMax - pMin < 0.025 {
            let w = pointWidth(pressure: (pMin + pMax) * 0.5, baseSize: baseSize, style: effectiveStyle, sensitivity: sensitivity)
            ctx.setLineWidth(w)
            ctx.addPath(buildSmoothPath(from: pts))
            ctx.strokePath()
            return
        }

        // Variable-width batched quadratic rendering (matches Pencil Ink's buildVariableBatches2alm)
        let tol = max(0.08, baseSize * 0.045)
        var prev = CGPoint(x: pts[0].x, y: pts[0].y)
        var curPath: CGMutablePath?
        var batchW = baseSize

        for i in 1..<n {
            let cur = pts[i]
            let target: CGPoint
            if i < n - 1 {
                target = CGPoint(x: (cur.x + pts[i + 1].x) * 0.5, y: (cur.y + pts[i + 1].y) * 0.5)
            } else {
                target = CGPoint(x: cur.x, y: cur.y)
            }
            let pAvg = (pts[i - 1].p + cur.p) * 0.5
            var w = pointWidth(pressure: pAvg, baseSize: baseSize, style: effectiveStyle, sensitivity: sensitivity)
            if n >= 6 && (i <= 2 || i >= n - 2) {
                let distEnd = CGFloat(min(i, n - 1 - i))
                w *= 0.78 + 0.22 * (distEnd / 2.0)
            }

            if curPath == nil {
                let p2 = CGMutablePath()
                p2.move(to: prev)
                curPath = p2
                batchW = w
            } else if abs(w - batchW) > tol {
                if let flush = curPath {
                    ctx.setLineWidth(batchW)
                    ctx.addPath(flush)
                    ctx.strokePath()
                }
                let p2 = CGMutablePath()
                p2.move(to: prev)
                curPath = p2
                batchW = w
            }

            if i < n - 1 {
                curPath?.addQuadCurve(to: target, control: CGPoint(x: cur.x, y: cur.y))
            } else {
                curPath?.addLine(to: target)
            }
            prev = target
        }

        if let flush = curPath {
            ctx.setLineWidth(batchW)
            ctx.addPath(flush)
            ctx.strokePath()
        }
    }

    /// Builds a GPU-ready `CGPath` for uniform-width strokes (ballpoint, highlighter, straight shapes)
    /// directly across `committed` + ephemeral `predicted` touches with ZERO temporary array copy at 240Hz!
    static func buildLiveUniformPath(committed: [InkPoint], predicted: [InkPoint], straight: Bool) -> CGPath {
        let cCount = committed.count
        let pCount = predicted.count
        let total = cCount + pCount
        guard total > 0 else { return CGMutablePath() }
        if pCount == 0 {
            return straight ? buildLinearPath(from: committed) : buildSmoothPath(from: committed)
        }
        @inline(__always)
        func ptAt(_ idx: Int) -> InkPoint {
            idx < cCount ? committed[idx] : predicted[idx - cCount]
        }
        let path = CGMutablePath()
        let p0 = ptAt(0)
        path.move(to: CGPoint(x: p0.x, y: p0.y))
        if total == 1 {
            path.addLine(to: CGPoint(x: p0.x + 0.05, y: p0.y))
            return path
        }
        if straight || total == 2 {
            for i in 1..<total {
                let p = ptAt(i)
                path.addLine(to: CGPoint(x: p.x, y: p.y))
            }
            return path
        }
        let p1 = ptAt(1)
        path.addLine(to: CGPoint(x: (p0.x + p1.x) * 0.5, y: (p0.y + p1.y) * 0.5))
        for i in 1..<(total - 1) {
            let cur = ptAt(i)
            let nxt = ptAt(i + 1)
            let mid = CGPoint(x: (cur.x + nxt.x) * 0.5, y: (cur.y + nxt.y) * 0.5)
            path.addQuadCurve(to: mid, control: CGPoint(x: cur.x, y: cur.y))
        }
        let last = ptAt(total - 1)
        path.addLine(to: CGPoint(x: last.x, y: last.y))
        return path
    }

    static func dirtyRect(for points: [InkPoint], baseSize: CGFloat, extraPad: CGFloat = 6.0) -> CGRect {
        guard !points.isEmpty else { return .null }
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for pt in points {
            if pt.x < minX { minX = pt.x }
            if pt.x > maxX { maxX = pt.x }
            if pt.y < minY { minY = pt.y }
            if pt.y > maxY { maxY = pt.y }
        }
        let pad = baseSize * 1.8 + extraPad
        return CGRect(x: minX - pad, y: minY - pad, width: max(1, maxX - minX) + pad * 2, height: max(1, maxY - minY) + pad * 2)
    }

    /// Zero-allocation committed stroke renderer: reads flat `[Double]` directly (no `[InkPoint]` temp array!)
    /// and accepts `overrideColor` so Dark Paper mode performs ZERO struct copies or hex round-trips.
    static func drawCommittedStroke(_ s: InkStroke, in ctx: CGContext, overrideColor: UIColor? = nil) {
        let n = s.pointCount
        guard n > 0 else { return }
        let isLinear = (s.straight == true)
        let style = s.tool == "highlighter" ? "ball" : (s.style ?? "ball")
        let color = overrideColor ?? UIColor.cached(hex: s.color)
        let baseSize = CGFloat(s.size)

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)

        if style == "ball" || isLinear || s._smartShape != nil {
            ctx.setLineWidth(baseSize)
            if n == 1 {
                let r = baseSize * 0.5 * 1.2
                ctx.fillEllipse(in: CGRect(x: CGFloat(s.pts[0]) - r, y: CGFloat(s.pts[1]) - r, width: r * 2, height: r * 2))
            } else {
                let path = isLinear ? buildLinearPath(from: s.pts) : buildSmoothPath(from: s.pts)
                ctx.addPath(path)
                ctx.strokePath()
            }
            return
        }

        let sensitivity = s._sens ?? 1.0
        if n == 1 {
            let w0 = pointWidth(pressure: CGFloat(s.pts[2]), baseSize: baseSize, style: style, sensitivity: sensitivity)
            let r = w0 * 0.5 * 1.2
            ctx.fillEllipse(in: CGRect(x: CGFloat(s.pts[0]) - r, y: CGFloat(s.pts[1]) - r, width: r * 2, height: r * 2))
            return
        }

        var pMin: CGFloat = 1.0
        var pMax: CGFloat = 0.0
        for i in 0..<n {
            let p = CGFloat(s.pts[i * 3 + 2])
            if p < pMin { pMin = p }
            if p > pMax { pMax = p }
        }
        if pMax - pMin < 0.025 {
            let w = pointWidth(pressure: (pMin + pMax) * 0.5, baseSize: baseSize, style: style, sensitivity: sensitivity)
            ctx.setLineWidth(w)
            ctx.addPath(buildSmoothPath(from: s.pts))
            ctx.strokePath()
            return
        }

        // Zero-allocation variable-width batched quadratic renderer reading directly from flat `s.pts`
        let tol = max(0.08, baseSize * 0.045)
        var prev = CGPoint(x: CGFloat(s.pts[0]), y: CGFloat(s.pts[1]))
        var curPath: CGMutablePath?
        var batchW = baseSize

        for i in 1..<n {
            let cx = CGFloat(s.pts[i * 3])
            let cy = CGFloat(s.pts[i * 3 + 1])
            let cp = CGFloat(s.pts[i * 3 + 2])
            let prevP = CGFloat(s.pts[(i - 1) * 3 + 2])
            let target: CGPoint
            if i < n - 1 {
                let nx = CGFloat(s.pts[(i + 1) * 3])
                let ny = CGFloat(s.pts[(i + 1) * 3 + 1])
                target = CGPoint(x: (cx + nx) * 0.5, y: (cy + ny) * 0.5)
            } else {
                target = CGPoint(x: cx, y: cy)
            }
            var w = pointWidth(pressure: (prevP + cp) * 0.5, baseSize: baseSize, style: style, sensitivity: sensitivity)
            if n >= 6 && (i <= 2 || i >= n - 2) {
                let distEnd = CGFloat(min(i, n - 1 - i))
                w *= 0.78 + 0.22 * (distEnd / 2.0)
            }

            if curPath == nil {
                let p2 = CGMutablePath()
                p2.move(to: prev)
                curPath = p2
                batchW = w
            } else if abs(w - batchW) > tol {
                if let flush = curPath {
                    ctx.setLineWidth(batchW)
                    ctx.addPath(flush)
                    ctx.strokePath()
                }
                let p2 = CGMutablePath()
                p2.move(to: prev)
                curPath = p2
                batchW = w
            }

            if i < n - 1 {
                curPath?.addQuadCurve(to: target, control: CGPoint(x: cx, y: cy))
            } else {
                curPath?.addLine(to: target)
            }
            prev = target
        }

        if let flush = curPath {
            ctx.setLineWidth(batchW)
            ctx.addPath(flush)
            ctx.strokePath()
        }
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
        guard n >= 2 else { return false }
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

    /// Exact Pixel Eraser segment-circle splitter (ported from Pencil Ink's `cutStroke`).
    /// Returns `nil` if the stroke was untouched, `[]` if erased completely, or 1+ split stroke pieces.
    static func cutStroke(_ s: InkStroke, at center: CGPoint, radius: CGFloat) -> [InkStroke]? {
        let n = s.pointCount
        guard n > 0 else { return nil }
        let R = radius + CGFloat(s.size) * 0.5
        let box = s.boundingBox().insetBy(dx: -R, dy: -R)
        guard box.contains(center) else { return nil }

        let x = Double(center.x)
        let y = Double(center.y)
        let rD = Double(R)
        let r2 = rD * rD
        let rRound: (Double) -> Double = { ($0 * 1000.0).rounded() / 1000.0 }

        if n == 1 {
            let dx0 = s.pts[0] - x
            let dy0 = s.pts[1] - y
            return (dx0 * dx0 + dy0 * dy0 <= r2) ? [] : nil
        }

        let xmin = x - rD, xmax = x + rD, ymin = y - rD, ymax = y + rD
        var pieces: [[Double]] = []
        var cur: [Double] = []
        var removed = 0

        var ax = s.pts[0]
        var ay = s.pts[1]
        var pa = s.pts[2]
        var aIn = (ax - x) * (ax - x) + (ay - y) * (ay - y) <= r2
        if aIn {
            removed += 1
        } else {
            cur.append(ax); cur.append(ay); cur.append(pa)
        }

        for i in 1..<n {
            let bx = s.pts[i * 3]
            let by = s.pts[i * 3 + 1]
            let pb = s.pts[i * 3 + 2]
            let bIn = (bx - x) * (bx - x) + (by - y) * (by - y) <= r2

            if !aIn && !bIn {
                if (ax < xmin && bx < xmin) || (ax > xmax && bx > xmax) || (ay < ymin && by < ymin) || (ay > ymax && by > ymax) {
                    cur.append(bx); cur.append(by); cur.append(pb)
                    ax = bx; ay = by; pa = pb; aIn = false
                    continue
                }
                let dx = bx - ax, dy = by - ay
                let a = dx * dx + dy * dy
                let fx = ax - x, fy = ay - y
                let bHalf = fx * dx + fy * dy
                let c = fx * fx + fy * fy - r2
                let disc = bHalf * bHalf - a * c
                if a > 1e-9 && disc > 0 {
                    let sq = sqrt(disc)
                    let t1 = (-bHalf - sq) / a
                    let t2 = (-bHalf + sq) / a
                    if t1 < 1.0 && t2 > 0.0 {
                        removed += 1
                        if t1 > 1e-3 {
                            cur.append(rRound(ax + dx * t1))
                            cur.append(rRound(ay + dy * t1))
                            cur.append(rRound(pa + (pb - pa) * t1))
                        }
                        if !cur.isEmpty {
                            pieces.append(cur)
                            cur = []
                        }
                        if t2 < 1.0 - 1e-3 {
                            cur.append(rRound(ax + dx * t2))
                            cur.append(rRound(ay + dy * t2))
                            cur.append(rRound(pa + (pb - pa) * t2))
                        }
                        cur.append(bx); cur.append(by); cur.append(pb)
                        ax = bx; ay = by; pa = pb; aIn = false
                        continue
                    }
                }
                cur.append(bx); cur.append(by); cur.append(pb)
            } else if !aIn && bIn {
                removed += 1
                let dx = bx - ax, dy = by - ay
                let a = dx * dx + dy * dy
                let fx = ax - x, fy = ay - y
                let bHalf = fx * dx + fy * dy
                let c = fx * fx + fy * fy - r2
                let disc = max(0.0, bHalf * bHalf - a * c)
                let t1 = a > 1e-9 ? max(0.0, min(1.0, (-bHalf - sqrt(disc)) / a)) : 0.0
                if t1 > 1e-3 {
                    cur.append(rRound(ax + dx * t1))
                    cur.append(rRound(ay + dy * t1))
                    cur.append(rRound(pa + (pb - pa) * t1))
                }
                if !cur.isEmpty {
                    pieces.append(cur)
                    cur = []
                }
            } else if aIn && !bIn {
                removed += 1
                let dx = bx - ax, dy = by - ay
                let a = dx * dx + dy * dy
                let fx = ax - x, fy = ay - y
                let bHalf = fx * dx + fy * dy
                let c = fx * fx + fy * fy - r2
                let disc = max(0.0, bHalf * bHalf - a * c)
                let t2 = a > 1e-9 ? max(0.0, min(1.0, (-bHalf + sqrt(disc)) / a)) : 1.0
                if t2 < 1.0 - 1e-3 {
                    cur.append(rRound(ax + dx * t2))
                    cur.append(rRound(ay + dy * t2))
                    cur.append(rRound(pa + (pb - pa) * t2))
                }
                cur.append(bx); cur.append(by); cur.append(pb)
            } else {
                removed += 1
            }
            ax = bx; ay = by; pa = pb; aIn = bIn
        }

        if !cur.isEmpty { pieces.append(cur) }
        guard removed > 0 else { return nil }

        return pieces.filter { $0.count >= 6 }.map { segPts in
            var copy = s
            copy.id = InkStroke.newID()
            copy.pts = segPts
            copy.straight = false
            copy._smartShape = nil
            return copy
        }
    }

    static func distPointSeg(px: CGFloat, py: CGFloat, ax: CGFloat, ay: CGFloat, bx: CGFloat, by: CGFloat) -> CGFloat {
        sqrt(segDistSq(px: px, py: py, ax: ax, ay: ay, bx: bx, by: by))
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
