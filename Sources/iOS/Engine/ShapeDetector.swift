import Foundation
import CoreGraphics

enum DetectedShapeGeom {
    case line(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat)
    case ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, isCircle: Bool)
    case rect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, isSquare: Bool)
    case triangle(v0: CGPoint, v1: CGPoint, v2: CGPoint)
}

struct DetectedShape {
    let kind: String          // "Line", "Circle", "Ellipse", "Square", "Rectangle", "Triangle"
    var geom: DetectedShapeGeom
    var points: [InkPoint]
    let straight: Bool
}

enum ShapeDetector {
    static func buildShapePoints(geom: DetectedShapeGeom, tStart: Double, tEnd: Double) -> [InkPoint] {
        func mk(_ x: CGFloat, _ y: CGFloat, _ idx: Int, _ tot: Int) -> InkPoint {
            let frac = Double(idx) / Double(max(1, tot))
            return InkPoint(x: x, y: y, p: 0.5, t: tStart + (tEnd - tStart) * frac)
        }
        switch geom {
        case let .line(x0, y0, x1, y1):
            return [mk(x0, y0, 0, 1), mk(x1, y1, 1, 1)]
        case let .ellipse(cx, cy, rx, ry, _):
            let steps = 64
            var out: [InkPoint] = []
            out.reserveCapacity(steps + 1)
            for s in 0...steps {
                let a = CGFloat(s) / CGFloat(steps) * CGFloat.pi * 2.0
                out.append(mk(cx + rx * cos(a), cy + ry * sin(a), s, steps))
            }
            return out
        case let .rect(x0, y0, x1, y1, _):
            return [
                mk(x0, y0, 0, 4),
                mk(x1, y0, 1, 4),
                mk(x1, y1, 2, 4),
                mk(x0, y1, 3, 4),
                mk(x0, y0, 4, 4)
            ]
        case let .triangle(v0, v1, v2):
            return [
                mk(v0.x, v0.y, 0, 3),
                mk(v1.x, v1.y, 1, 3),
                mk(v2.x, v2.y, 2, 3),
                mk(v0.x, v0.y, 3, 3)
            ]
        }
    }

    static func dedupe(_ raw: [InkPoint], minDist: CGFloat = 1.0) -> [InkPoint] {
        var out: [InkPoint] = []
        for q in raw {
            if let last = out.last {
                if hypot(q.x - last.x, q.y - last.y) >= minDist {
                    out.append(q)
                }
            } else {
                out.append(q)
            }
        }
        if let lastRaw = raw.last, let lastOut = out.last, hypot(lastRaw.x - lastOut.x, lastRaw.y - lastOut.y) > 0.01 {
            out.append(lastRaw)
        }
        return out
    }

    static func detect(from rawPts: [InkPoint], zoomScale: CGFloat) -> DetectedShape? {
        let pts = dedupe(rawPts, minDist: 1.0)
        guard pts.count >= 8 else { return nil }

        var len: CGFloat = 0
        var x0 = CGFloat.greatestFiniteMagnitude
        var y0 = CGFloat.greatestFiniteMagnitude
        var x1 = -CGFloat.greatestFiniteMagnitude
        var y1 = -CGFloat.greatestFiniteMagnitude
        for i in 0..<pts.count {
            let q = pts[i]
            if q.x < x0 { x0 = q.x }
            if q.x > x1 { x1 = q.x }
            if q.y < y0 { y0 = q.y }
            if q.y > y1 { y1 = q.y }
            if i > 0 {
                len += hypot(q.x - pts[i - 1].x, q.y - pts[i - 1].y)
            }
        }
        let bw = x1 - x0
        let bh = y1 - y0
        let diag = hypot(bw, bh)
        let minScreenPt = 32.0 / max(0.5, zoomScale)
        guard diag >= minScreenPt, len >= minScreenPt else { return nil }

        let start = pts[0]
        let end = pts[pts.count - 1]
        let chord = hypot(end.x - start.x, end.y - start.y)
        let tStart = start.t
        let tEnd = max(end.t, tStart + 0.05)

        // Handwriting rejection: sharp turns & excessive winding
        var sharpTurns = 0
        var totalTurnRad: CGFloat = 0
        let step = max(1, pts.count / 28)
        if pts.count > step * 2 {
            var i = step
            while i < pts.count - step {
                let a = pts[i - step], b = pts[i], c = pts[i + step]
                let ux = b.x - a.x, uy = b.y - a.y
                let vx = c.x - b.x, vy = c.y - b.y
                let lu = hypot(ux, uy), lv = hypot(vx, vy)
                if lu > 1.5 && lv > 1.5 {
                    let dot = (ux * vx + uy * vy) / (lu * lv)
                    let clampedDot = max(-1.0, min(1.0, dot))
                    let cross = ux * vy - uy * vx
                    totalTurnRad += atan2(cross, ux * vx + uy * vy)
                    if clampedDot < 0.25 { sharpTurns += 1 }
                }
                i += step
            }
        }
        if sharpTurns > 5 || abs(totalTurnRad) > CGFloat.pi * 2.85 { return nil }

        // 1. Straight Line
        if chord / len >= 0.925 && sharpTurns <= 1 {
            var maxDev: CGFloat = 0
            for i in 1..<(pts.count - 1) {
                let d = StrokeGeometry.distPointSeg(px: pts[i].x, py: pts[i].y, ax: start.x, ay: start.y, bx: end.x, by: end.y)
                if d > maxDev { maxDev = d }
            }
            if maxDev <= max(6.0, chord * 0.055) {
                var ex = end.x
                var ey = end.y
                let dx = ex - start.x
                let dy = ey - start.y
                let ang = atan2(abs(dy), abs(dx)) * 180.0 / CGFloat.pi
                if ang < 5.0 {
                    ey = start.y
                } else if ang > 85.0 {
                    ex = start.x
                } else if abs(ang - 45.0) < 4.0 {
                    let avg = (abs(dx) + abs(dy)) * 0.5
                    ex = start.x + (dx >= 0 ? avg : -avg)
                    ey = start.y + (dy >= 0 ? avg : -avg)
                }
                let geom = DetectedShapeGeom.line(x0: start.x, y0: start.y, x1: ex, y1: ey)
                return DetectedShape(
                    kind: "Line",
                    geom: geom,
                    points: buildShapePoints(geom: geom, tStart: tStart, tEnd: tEnd),
                    straight: true
                )
            }
        }

        // 2. Closed Shapes
        if chord <= max(26.0 / max(0.5, zoomScale), diag * 0.28) && bw >= 18 && bh >= 18 && abs(totalTurnRad) >= CGFloat.pi * 1.35 {
            let cx = (x0 + x1) * 0.5
            let cy = (y0 + y1) * 0.5
            let rx = bw * 0.5
            let ry = bh * 0.5
            var radErrSum: CGFloat = 0
            var rectErrSum: CGFloat = 0
            for q in pts {
                let normR = hypot((q.x - cx) / max(1.0, rx), (q.y - cy) / max(1.0, ry))
                radErrSum += abs(normR - 1.0)
                let dEdge = min(min(abs(q.x - x0), abs(q.x - x1)), min(abs(q.y - y0), abs(q.y - y1)))
                rectErrSum += dEdge / max(1.0, min(bw, bh))
            }
            let meanRadErr = radErrSum / CGFloat(pts.count)
            let meanRectErr = rectErrSum / CGFloat(pts.count)

            // Circle / Ellipse
            if meanRadErr < 0.145 && meanRadErr < meanRectErr * 1.05 && sharpTurns <= 2 {
                let isCircle = abs(rx - ry) / max(rx, ry) < 0.16
                let rAvg = (rx + ry) * 0.5
                let geom = DetectedShapeGeom.ellipse(
                    cx: cx, cy: cy,
                    rx: isCircle ? rAvg : rx,
                    ry: isCircle ? rAvg : ry,
                    isCircle: isCircle
                )
                return DetectedShape(
                    kind: isCircle ? "Circle" : "Ellipse",
                    geom: geom,
                    points: buildShapePoints(geom: geom, tStart: tStart, tEnd: tEnd),
                    straight: false
                )
            }

            // Square / Rectangle
            if meanRectErr < 0.125 && sharpTurns >= 2 && sharpTurns <= 5 {
                let isSquare = abs(bw - bh) / max(bw, bh) < 0.14
                var rx0 = x0, ry0 = y0, rx1 = x1, ry1 = y1
                if isSquare {
                    let half = (bw + bh) * 0.25
                    rx0 = cx - half; rx1 = cx + half
                    ry0 = cy - half; ry1 = cy + half
                }
                let geom = DetectedShapeGeom.rect(x0: rx0, y0: ry0, x1: rx1, y1: ry1, isSquare: isSquare)
                return DetectedShape(
                    kind: isSquare ? "Square" : "Rectangle",
                    geom: geom,
                    points: buildShapePoints(geom: geom, tStart: tStart, tEnd: tEnd),
                    straight: true
                )
            }

            // Triangle
            if sharpTurns >= 2 && sharpTurns <= 4 {
                var pA = pts[0], maxDA: CGFloat = -1
                for q in pts {
                    let d = hypot(q.x - cx, q.y - cy)
                    if d > maxDA { maxDA = d; pA = q }
                }
                var pB = pts[0], maxDB: CGFloat = -1
                for q in pts {
                    let d = hypot(q.x - pA.x, q.y - pA.y)
                    if d > maxDB { maxDB = d; pB = q }
                }
                var pC = pts[0], maxDC: CGFloat = -1
                for q in pts {
                    let d = StrokeGeometry.distPointSeg(px: q.x, py: q.y, ax: pA.x, ay: pA.y, bx: pB.x, by: pB.y)
                    if d > maxDC { maxDC = d; pC = q }
                }
                if maxDC > diag * 0.25 {
                    var triErrSum: CGFloat = 0
                    for q in pts {
                        let d1 = StrokeGeometry.distPointSeg(px: q.x, py: q.y, ax: pA.x, ay: pA.y, bx: pB.x, by: pB.y)
                        let d2 = StrokeGeometry.distPointSeg(px: q.x, py: q.y, ax: pB.x, ay: pB.y, bx: pC.x, by: pC.y)
                        let d3 = StrokeGeometry.distPointSeg(px: q.x, py: q.y, ax: pC.x, ay: pC.y, bx: pA.x, by: pA.y)
                        triErrSum += min(d1, min(d2, d3)) / diag
                    }
                    if triErrSum / CGFloat(pts.count) < 0.085 {
                        let geom = DetectedShapeGeom.triangle(
                            v0: CGPoint(x: pA.x, y: pA.y),
                            v1: CGPoint(x: pB.x, y: pB.y),
                            v2: CGPoint(x: pC.x, y: pC.y)
                        )
                        return DetectedShape(
                            kind: "Triangle",
                            geom: geom,
                            points: buildShapePoints(geom: geom, tStart: tStart, tEnd: tEnd),
                            straight: true
                        )
                    }
                }
            }
        }
        return nil
    }
}
