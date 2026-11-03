//
//  FieldGeometry.swift
//  Conspire
//

import CoreGraphics
import Foundation
import SwiftUI

/// Closed outline of a field, as a dense ring of world-space points.
typealias FieldRing = [CGPoint]

enum FieldCombineMode {
    case union
    case subtract
}

/// Geometry for fields (zones).
///
/// A field is one closed outline stored as a dense, roughly uniform ring
/// (`ringSpacing` apart) and drawn as a closed Catmull-Rom spline. Dense and
/// uniform is what makes falloff sculpting read as smooth rather than kinked.
///
/// Every operation that changes topology — merging a new stroke, carving one
/// out, repairing an outline dragged through itself — goes through `combine`:
/// rasterise signed distance onto a grid, blend with a smooth min, march the
/// zero contour, keep the largest loop. The smooth min fillets the join between
/// two blobs, and keeping only the largest loop enforces "one outline, no holes".
enum FieldGeometry {

    /// World px between ring points.
    static let ringSpacing: CGFloat = 16
    /// Strokes smaller than this are treated as an accidental dab.
    static let minArea: CGFloat = 1600
    /// Screen px within which a press grabs an outline.
    static let edgeGrab: CGFloat = 14

    private static let epsilon: CGFloat = 1e-9

    // MARK: - Basics

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func closedLength(_ ring: FieldRing) -> CGFloat {
        guard ring.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in ring.indices {
            total += distance(ring[i], ring[(i + 1) % ring.count])
        }
        return total
    }

    /// Signed area (shoelace). Sign tells winding direction; callers usually want `abs`.
    static func area(_ ring: FieldRing) -> CGFloat {
        guard ring.count > 2 else { return 0 }
        var sum: CGFloat = 0
        var j = ring.count - 1
        for i in ring.indices {
            sum += ring[j].x * ring[i].y - ring[i].x * ring[j].y
            j = i
        }
        return sum / 2
    }

    static func bounds(_ ring: FieldRing) -> CGRect {
        guard let first = ring.first else { return .null }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in ring.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func centroid(_ ring: FieldRing) -> CGPoint {
        guard !ring.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for p in ring { x += p.x; y += p.y }
        return CGPoint(x: x / CGFloat(ring.count), y: y / CGFloat(ring.count))
    }

    static func contains(_ ring: FieldRing, _ point: CGPoint) -> Bool {
        guard ring.count > 2 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[j], b = ring[i]
            if (b.y > point.y) != (a.y > point.y),
               point.x < (a.x - b.x) * (point.y - b.y) / (a.y - b.y) + b.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    struct Nearest {
        var distance: CGFloat
        /// Index of the ring segment's start point.
        var index: Int
        /// Position along that segment, 0...1.
        var t: CGFloat
        var point: CGPoint
    }

    static func nearest(on ring: FieldRing, to point: CGPoint) -> Nearest? {
        guard ring.count > 2 else { return nil }
        var best = Nearest(distance: .greatestFiniteMagnitude, index: 0, t: 0, point: ring[0])
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let vx = b.x - a.x, vy = b.y - a.y
            let len2 = vx * vx + vy * vy
            var t: CGFloat = len2 > epsilon ? ((point.x - a.x) * vx + (point.y - a.y) * vy) / len2 : 0
            t = min(max(t, 0), 1)
            let q = CGPoint(x: a.x + vx * t, y: a.y + vy * t)
            let d = distance(point, q)
            if d < best.distance {
                best = Nearest(distance: d, index: i, t: t, point: q)
            }
        }
        return best
    }

    // MARK: - Ring conditioning

    /// Walk the closed polyline, dropping a point every `spacing` of arc length.
    static func resampleClosed(_ ring: FieldRing, spacing: CGFloat) -> FieldRing {
        let n = ring.count
        guard n > 2 else { return ring }
        let total = closedLength(ring)
        guard total > spacing * 3 else { return ring }

        let count = max(10, Int((total / spacing).rounded()))
        let step = total / CGFloat(count)

        var out: FieldRing = []
        out.reserveCapacity(count)

        var segmentIndex = 0
        var travelled: CGFloat = 0
        var a = ring[0]
        var b = ring[1 % n]
        var segLen = distance(a, b)

        for k in 0..<count {
            let target = CGFloat(k) * step
            var guardCount = 0
            while travelled + segLen < target && guardCount < n * 2 {
                travelled += segLen
                segmentIndex += 1
                a = ring[segmentIndex % n]
                b = ring[(segmentIndex + 1) % n]
                segLen = distance(a, b)
                guardCount += 1
            }
            let t: CGFloat = segLen > epsilon ? (target - travelled) / segLen : 0
            out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return out
    }

    /// Weighted [0.25, 0.5, 0.25] passes around the ring: removes hand wobble, keeps big features.
    static func smooth(_ ring: FieldRing, passes: Int) -> FieldRing {
        guard passes > 0, ring.count > 2 else { return ring }
        var current = ring
        for _ in 0..<passes {
            let n = current.count
            var next = current
            for i in 0..<n {
                let a = current[(i - 1 + n) % n]
                let b = current[i]
                let c = current[(i + 1) % n]
                next[i] = CGPoint(
                    x: a.x * 0.25 + b.x * 0.5 + c.x * 0.25,
                    y: a.y * 0.25 + b.y * 0.5 + c.y * 0.25
                )
            }
            current = next
        }
        return current
    }

    static func normalize(_ ring: FieldRing, passes: Int = 0) -> FieldRing {
        smooth(resampleClosed(ring, spacing: ringSpacing), passes: passes)
    }

    /// Closed Catmull-Rom through the ring, emitted as cubic Béziers.
    static func path(_ ring: FieldRing) -> Path {
        var p = Path()
        let n = ring.count
        guard n > 2 else { return p }
        p.move(to: ring[0])
        for i in 0..<n {
            let p0 = ring[(i - 1 + n) % n]
            let p1 = ring[i]
            let p2 = ring[(i + 1) % n]
            let p3 = ring[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
        p.closeSubpath()
        return p
    }

    private static func segmentsCross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func orient(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let d1 = orient(a, b, c), d2 = orient(a, b, d)
        let d3 = orient(c, d, a), d4 = orient(c, d, b)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }

    static func selfIntersects(_ ring: FieldRing) -> Bool {
        let n = ring.count
        guard n > 3 else { return false }
        for i in 0..<n {
            var j = i + 2
            while j < n {
                defer { j += 1 }
                if i == 0 && j == n - 1 { continue }   // adjacent across the seam
                if segmentsCross(ring[i], ring[(i + 1) % n], ring[j], ring[(j + 1) % n]) {
                    return true
                }
            }
        }
        return false
    }

    /// Resolve an outline that crossed itself, reusing the contouring machinery.
    static func repairIfNeeded(_ ring: FieldRing) -> FieldRing {
        guard selfIntersects(ring) else { return ring }
        return combine(ring, ring, mode: .union, soft: 0.001) ?? ring
    }

    // MARK: - Signed distance

    /// Edge data flattened to one allocation, five values per edge:
    /// start x, start y, delta x, delta y, 1/|delta|². Precomputing the
    /// reciprocal keeps a divide out of the inner loop, which runs once per
    /// edge per grid node.
    private static let edgeStride = 5

    private static func flattenEdges(_ ring: FieldRing) -> [CGFloat] {
        let n = ring.count
        var out = [CGFloat](repeating: 0, count: n * edgeStride)
        var j = n - 1
        for i in 0..<n {
            let a = ring[j], b = ring[i]
            let vx = b.x - a.x, vy = b.y - a.y
            let len2 = vx * vx + vy * vy
            let base = i * edgeStride
            out[base] = a.x
            out[base + 1] = a.y
            out[base + 2] = vx
            out[base + 3] = vy
            out[base + 4] = len2 > epsilon ? 1 / len2 : 0
            j = i
        }
        return out
    }

    /// Negative inside the polygon, positive outside.
    @inline(__always)
    private static func signedDistance(
        edges: UnsafePointer<CGFloat>, count: Int, px: CGFloat, py: CGFloat
    ) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        var inside = false
        for i in 0..<count {
            let base = i * edgeStride
            let ax = edges[base]
            let ay = edges[base + 1]
            let vx = edges[base + 2]
            let vy = edges[base + 3]
            let invLen2 = edges[base + 4]

            var t = ((px - ax) * vx + (py - ay) * vy) * invLen2
            t = t < 0 ? 0 : (t > 1 ? 1 : t)
            let dx = px - (ax + vx * t)
            let dy = py - (ay + vy * t)
            let d2 = dx * dx + dy * dy
            if d2 < best { best = d2 }

            let by = ay + vy
            if (by > py) != (ay > py) {
                // Crossing test, with the segment endpoints written as a + v.
                if px < vx * (py - by) / vy + (ax + vx) { inside.toggle() }
            }
        }
        let d = sqrt(best)
        return inside ? -d : d
    }

    /// Polynomial smooth minimum — this is what fillets the join between two blobs.
    static func smoothMin(_ a: CGFloat, _ b: CGFloat, _ k: CGFloat) -> CGFloat {
        guard k > epsilon else { return min(a, b) }
        var h = 0.5 + 0.5 * (b - a) / k
        h = min(max(h, 0), 1)
        return b * (1 - h) + a * h - k * h * (1 - h)
    }

    static func smoothMax(_ a: CGFloat, _ b: CGFloat, _ k: CGFloat) -> CGFloat {
        -smoothMin(-a, -b, k)
    }

    /// Distance from a point to a rect; 0 when inside. A lower bound on |sdf| of
    /// anything contained by that rect, used to skip exact distance work.
    private static func rectLowerBound(_ r: CGRect, _ px: CGFloat, _ py: CGFloat) -> CGFloat {
        let dx = max(r.minX - px, 0, px - r.maxX)
        let dy = max(r.minY - py, 0, py - r.maxY)
        return hypot(dx, dy)
    }

    // MARK: - Marching squares

    // Edge ids: 0 = bottom, 1 = right, 2 = top, 3 = left.
    private static let marchTable: [[Int]] = [
        [], [3, 0], [0, 1], [3, 1], [1, 2], [3, 0, 1, 2], [0, 2], [3, 2],
        [2, 3], [2, 0], [0, 1, 2, 3], [2, 1], [1, 3], [1, 0], [3, 0], []
    ]

    private struct GridKey: Hashable {
        let x: Int32
        let y: Int32
    }

    private static func gridKey(_ p: CGPoint) -> GridKey {
        GridKey(x: Int32((p.x * 64).rounded()), y: Int32((p.y * 64).rounded()))
    }

    private static func marchingSquares(
        field: [CGFloat], nx: Int, ny: Int, x0: CGFloat, y0: CGFloat, step: CGFloat
    ) -> [FieldRing] {
        var segments: [(CGPoint, CGPoint)] = []

        func interpolate(_ va: CGFloat, _ vb: CGFloat) -> CGFloat {
            let dv = va - vb
            return abs(dv) < epsilon ? 0.5 : va / dv
        }

        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let v00 = field[j * nx + i]
                let v10 = field[j * nx + i + 1]
                let v11 = field[(j + 1) * nx + i + 1]
                let v01 = field[(j + 1) * nx + i]

                var code = 0
                if v00 < 0 { code |= 1 }
                if v10 < 0 { code |= 2 }
                if v11 < 0 { code |= 4 }
                if v01 < 0 { code |= 8 }

                let edges = marchTable[code]
                if edges.isEmpty { continue }

                func edgePoint(_ e: Int) -> CGPoint {
                    switch e {
                    case 0:
                        return CGPoint(x: x0 + (CGFloat(i) + interpolate(v00, v10)) * step,
                                       y: y0 + CGFloat(j) * step)
                    case 1:
                        return CGPoint(x: x0 + CGFloat(i + 1) * step,
                                       y: y0 + (CGFloat(j) + interpolate(v10, v11)) * step)
                    case 2:
                        return CGPoint(x: x0 + (CGFloat(i) + interpolate(v01, v11)) * step,
                                       y: y0 + CGFloat(j + 1) * step)
                    default:
                        return CGPoint(x: x0 + CGFloat(i) * step,
                                       y: y0 + (CGFloat(j) + interpolate(v00, v01)) * step)
                    }
                }

                var e = 0
                while e < edges.count {
                    segments.append((edgePoint(edges[e]), edgePoint(edges[e + 1])))
                    e += 2
                }
            }
        }

        guard !segments.isEmpty else { return [] }

        // Stitch undirected segments into closed loops by shared endpoints.
        var nodes: [GridKey: [(index: Int, end: Int)]] = [:]
        for (idx, seg) in segments.enumerated() {
            nodes[gridKey(seg.0), default: []].append((idx, 0))
            nodes[gridKey(seg.1), default: []].append((idx, 1))
        }

        var used = [Bool](repeating: false, count: segments.count)
        var loops: [FieldRing] = []

        for start in segments.indices where !used[start] {
            used[start] = true
            var loop: FieldRing = [segments[start].0, segments[start].1]
            let startKey = gridKey(segments[start].0)
            var tailKey = gridKey(segments[start].1)

            for _ in 0...(segments.count) {
                guard let links = nodes[tailKey],
                      let next = links.first(where: { !used[$0.index] }) else { break }
                used[next.index] = true
                let other = next.end == 0 ? segments[next.index].1 : segments[next.index].0
                loop.append(other)
                tailKey = gridKey(other)
                if tailKey == startKey { break }
            }
            if loop.count >= 4 { loops.append(loop) }
        }
        return loops
    }

    // MARK: - Combining

    /// Union or subtract `b` from `a`. Returns a conditioned ring, or nil if nothing survives.
    static func combine(
        _ a: FieldRing, _ b: FieldRing, mode: FieldCombineMode, soft: CGFloat
    ) -> FieldRing? {
        guard a.count > 2, b.count > 2 else { return nil }

        let boxA = bounds(a)
        let boxB = bounds(b)
        // A subtraction can only shrink A, so its grid never needs to cover B.
        let box = mode == .subtract ? boxA : boxA.union(boxB)
        let pad = soft + 16
        let x0 = box.minX - pad
        let y0 = box.minY - pad
        let width = box.width + pad * 2
        let height = box.height + pad * 2

        // Cap the grid so a huge field stays responsive. The contour is resampled
        // and smoothed afterwards, so 5pt of resolution is visually plenty.
        let step = max(5, max(width, height) / 110)
        let nx = Int((width / step).rounded(.up)) + 1
        let ny = Int((height / step).rounded(.up)) + 1
        guard nx > 2, ny > 2 else { return nil }

        let edgesA = flattenEdges(a)
        let edgesB = flattenEdges(b)
        let countA = a.count
        let countB = b.count

        var field = [CGFloat](repeating: 0, count: nx * ny)
        let carve = (mode == .subtract)
        let carveSoft = min(soft, 10)

        edgesA.withUnsafeBufferPointer { bufferA in
            edgesB.withUnsafeBufferPointer { bufferB in
                field.withUnsafeMutableBufferPointer { out in
                    guard let pa = bufferA.baseAddress, let pb = bufferB.baseAddress else { return }

                    for j in 0..<ny {
                        let py = y0 + CGFloat(j) * step
                        for i in 0..<nx {
                            let px = x0 + CGFloat(i) * step

                            // Well outside both outlines the exact value cannot move
                            // the contour, so skip the per-edge work entirely.
                            let lowerA = rectLowerBound(boxA, px, py)
                            if !carve {
                                let lowerB = rectLowerBound(boxB, px, py)
                                let nearest = min(lowerA, lowerB)
                                if nearest > soft + step {
                                    out[j * nx + i] = nearest
                                    continue
                                }
                            } else if lowerA > carveSoft + step {
                                out[j * nx + i] = lowerA
                                continue
                            }

                            let da = signedDistance(edges: pa, count: countA, px: px, py: py)
                            if carve {
                                let db = signedDistance(edges: pb, count: countB, px: px, py: py)
                                out[j * nx + i] = smoothMax(da, -db, carveSoft)
                            } else {
                                // Far from B the smooth min collapses to `da`.
                                let lowerB = rectLowerBound(boxB, px, py)
                                if lowerB > 0 && lowerB >= da + soft {
                                    out[j * nx + i] = da
                                } else {
                                    let db = signedDistance(edges: pb, count: countB, px: px, py: py)
                                    out[j * nx + i] = smoothMin(da, db, soft)
                                }
                            }
                        }
                    }
                }
            }
        }

        let loops = marchingSquares(field: field, nx: nx, ny: ny, x0: x0, y0: y0, step: step)
        guard !loops.isEmpty else { return nil }

        // Keeping only the largest loop drops holes and stray islands, so a field
        // is always a single closed outline.
        var best: FieldRing?
        var bestArea: CGFloat = 0
        for loop in loops {
            let loopArea = abs(area(loop))
            if loopArea > bestArea { bestArea = loopArea; best = loop }
        }
        guard let best, bestArea >= minArea else { return nil }
        return normalize(best, passes: 1)
    }

    // MARK: - Sculpting

    struct ArcInfluence {
        /// Per-ring-point weight, 0...1.
        var weights: [CGFloat]
        /// Affected indices in walk order, for drawing the highlight as one arc.
        var indices: [Int]
    }

    /// Falloff weights by arc-length distance from the grabbed point, so the far
    /// side of a thin shape stays put even when it is close in straight-line terms.
    static func arcInfluence(ring: FieldRing, near: Nearest, radius: CGFloat) -> ArcInfluence {
        let n = ring.count
        guard n > 2, radius > epsilon else {
            return ArcInfluence(weights: [CGFloat](repeating: 0, count: n), indices: [])
        }

        var arcStart = [CGFloat](repeating: 0, count: n)
        var total: CGFloat = 0
        for i in 0..<n {
            arcStart[i] = total
            total += distance(ring[i], ring[(i + 1) % n])
        }
        guard total > epsilon else {
            return ArcInfluence(weights: [CGFloat](repeating: 0, count: n), indices: [])
        }

        let hit = arcStart[near.index] + near.t * distance(ring[near.index], ring[(near.index + 1) % n])

        var weights = [CGFloat](repeating: 0, count: n)
        var affected: [Int] = []
        for i in 0..<n {
            var d = abs(arcStart[i] - hit)
            d = min(d, total - d)
            let t = d / radius
            if t < 1 {
                let u = 1 - t * t
                weights[i] = u * u
                affected.append(i)
            }
        }
        return ArcInfluence(weights: weights, indices: orderArc(affected, count: n))
    }

    /// Put affected indices in walk order starting at the run's first point.
    private static func orderArc(_ indices: [Int], count n: Int) -> [Int] {
        guard !indices.isEmpty else { return [] }
        let set = Set(indices)
        var start = indices[0]
        for i in indices where !set.contains((i - 1 + n) % n) {
            start = i
            break
        }
        var out: [Int] = []
        var cursor = start
        for _ in indices.indices {
            out.append(cursor)
            cursor = (cursor + 1) % n
            if !set.contains(cursor) { break }
        }
        return out
    }

    /// Evenly spaced control handles for the handle-reshape mode.
    static func handleIndices(_ ring: FieldRing, desired: Int = 14) -> [Int] {
        guard ring.count > 2 else { return [] }
        let stride = max(2, Int((Double(ring.count) / Double(desired)).rounded()))
        return Swift.stride(from: 0, to: ring.count, by: stride).map { $0 }
    }

    static func handleStride(_ ring: FieldRing, desired: Int = 14) -> Int {
        max(2, Int((Double(ring.count) / Double(desired)).rounded()))
    }
}
