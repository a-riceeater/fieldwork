import Foundation
import DrillTiming

/// A point or vector in world meters. Origin is field center, +x toward the
/// audience's right (looking from the front stands), +y toward the back sideline.
public struct Point2: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2(0, 0)

    public static func + (a: Point2, b: Point2) -> Point2 { Point2(a.x + b.x, a.y + b.y) }
    public static func - (a: Point2, b: Point2) -> Point2 { Point2(a.x - b.x, a.y - b.y) }
    public static func * (a: Point2, s: Double) -> Point2 { Point2(a.x * s, a.y * s) }
    public static func / (a: Point2, s: Double) -> Point2 { Point2(a.x / s, a.y / s) }

    public var length: Double { (x * x + y * y).squareRoot() }
    public func distance(to other: Point2) -> Double { (self - other).length }
    public func dot(_ other: Point2) -> Double { x * other.x + y * other.y }
    public var perpendicular: Point2 { Point2(-y, x) }
    public var normalized: Point2 { length > 0 ? self / length : .zero }
    public func lerp(to other: Point2, _ t: Double) -> Point2 { self + (other - self) * t }

    public var description: String { "(\(TimeFormat.decimal(x, places: 3)), \(TimeFormat.decimal(y, places: 3)))" }
}

/// Axis-aligned rectangle in world meters.
public struct Rect2: Hashable, Codable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public init(points: [Point2]) {
        self.init(minX: points.map(\.x).min() ?? 0, minY: points.map(\.y).min() ?? 0,
                  maxX: points.map(\.x).max() ?? 0, maxY: points.map(\.y).max() ?? 0)
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: Point2 { Point2((minX + maxX) / 2, (minY + maxY) / 2) }

    public func contains(_ p: Point2, tolerance: Double = 0) -> Bool {
        p.x >= minX - tolerance && p.x <= maxX + tolerance && p.y >= minY - tolerance && p.y <= maxY + tolerance
    }

    public func intersects(_ other: Rect2) -> Bool {
        minX <= other.maxX && maxX >= other.minX && minY <= other.maxY && maxY >= other.minY
    }

    public func insetBy(_ d: Double) -> Rect2 { Rect2(minX: minX + d, minY: minY + d, maxX: maxX - d, maxY: maxY - d) }
}

/// Retained control geometry of a form. Positions are derived from it.
public enum FormGeometry: Hashable, Codable, Sendable {
    /// Straight line from `start` to `end`.
    case line(start: Point2, end: Point2)
    /// Circular arc from `start` to `end`. `bulge` is the signed sagitta in meters:
    /// positive bulges to the left of the start→end direction.
    case arc(start: Point2, end: Point2, bulge: Double)

    /// Smooth interpolating spline through ordered endpoints and shaping points.
    case curve(points: [Point2])

    case circle(center: Point2, radius: Double)

    public var kindName: String {
        switch self {
        case .curve: return "Curve"
        case .line: return "Line"
        case .arc: return "Arc"
        case .circle: return "Circle"
        }
    }

    public var endpoints: (Point2, Point2) {
        switch self {
        case .line(let s, let e), .arc(let s, let e, _): return (s, e)
        case .curve(let points): return (points.first ?? .zero, points.last ?? .zero)
        case .circle(let c, let r): return (c, c + Point2(r, 0))
        }
    }

    /// Handles a canvas shows for direct editing: endpoints plus the arc midpoint.
    public var handles: [Point2] {
        switch self {
        case .curve(let points): return points
        case .line(let s, let e): return [s, e]
        case .arc(let s, let e, _): return [s, e, point(at: 0.5)]
        case .circle(let c, let r): return [c, c + Point2(r, 0), c + Point2(0, r), c - Point2(r, 0), c - Point2(0, r)]
        }
    }

    public func translated(by d: Point2) -> FormGeometry {
        switch self {
        case .curve(let points): return .curve(points: points.map { $0 + d })
        case .line(let s, let e): return .line(start: s + d, end: e + d)
        case .arc(let s, let e, let b): return .arc(start: s + d, end: e + d, bulge: b)
        case .circle(let c, let r): return .circle(center: c + d, radius: r)
        }
    }

    /// Straight-line distance between adjacent performers, including the closing pair.
    public func neighborSpacing(count: Int) -> Double {
        guard count > 1 else { return 0 }
        if case .circle(_, let radius) = self {
            return 2 * radius * sin(.pi / Double(count))
        }
        return length / Double(count - 1)
    }

    public static func circleRadius(spacing: Double, count: Int) -> Double {
        count > 1 ? spacing / (2 * sin(.pi / Double(count))) : spacing
    }

    /// Circle parameters for a non-degenerate arc.
    var circle: (center: Point2, radius: Double, startAngle: Double, sweep: Double)? {
        guard case .arc(let s, let e, let bulge) = self else { return nil }
        let chord = e - s
        let c = chord.length
        guard c > 1e-9, abs(bulge) > 1e-9 else { return nil }
        let h = c / 2
        let radius = (h * h + bulge * bulge) / (2 * abs(bulge))
        let mid = s.lerp(to: e, 0.5)
        let left = chord.perpendicular.normalized
        let apex = mid + left * bulge
        // Center lies on the perpendicular through mid, on the opposite side of the apex.
        let center = apex - left * (bulge > 0 ? radius : -radius)
        let a0 = atan2(s.y - center.y, s.x - center.x)
        let a1 = atan2(e.y - center.y, e.x - center.x)
        let aApex = atan2(apex.y - center.y, apex.x - center.x)
        // Choose the sweep direction that passes through the apex.
        var ccw = a1 - a0
        while ccw <= 0 { ccw += 2 * .pi }
        var apexOffset = aApex - a0
        while apexOffset < 0 { apexOffset += 2 * .pi }
        let sweep = apexOffset <= ccw ? ccw : ccw - 2 * .pi
        return (center, radius, a0, sweep)
    }

    /// Total length along the form.
    public var length: Double {
        switch self {
        case .curve:
            let samples = polyline()
            return zip(samples, samples.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        case .circle(_, let r): return 2 * .pi * r
        case .line(let s, let e): return s.distance(to: e)
        case .arc(let s, let e, _):
            guard let c = circle else { return s.distance(to: e) }
            return abs(c.sweep) * c.radius
        }
    }

    /// Point at normalized arc length `t` in 0...1 (exact for lines and circular arcs).
    public func point(at t: Double) -> Point2 {
        switch self {
        case .curve:
            return Self.samplePolyline(polyline(), at: t)
        case .circle(let c, let r):
            let angle = -Double.pi / 2 + 2 * .pi * t
            return c + Point2(r * cos(angle), r * sin(angle))
        case .line(let s, let e):
            return s.lerp(to: e, t)
        case .arc(let s, let e, _):
            guard let c = circle else { return s.lerp(to: e, t) }
            let angle = c.startAngle + c.sweep * t
            return Point2(c.center.x + c.radius * cos(angle), c.center.y + c.radius * sin(angle))
        }
    }

    /// `count` points at equal arc-length spacing, endpoints included.
    public func distribute(_ count: Int) -> [Point2] {
        guard count > 0 else { return [] }
        if case .curve = self {
            let samples = polyline()
            return (0..<count).map { Self.samplePolyline(samples, at: count == 1 ? 0.5 : Double($0) / Double(count - 1)) }
        }
        if case .circle = self {
            return (0..<count).map { point(at: Double($0) / Double(count)) }
        }
        if count == 1 { return [point(at: 0.5)] }
        return (0..<count).map { point(at: Double($0) / Double(count - 1)) }
    }

    /// Sampled polyline for drawing.
    public func polyline(segments: Int = 48) -> [Point2] {
        switch self {
        case .curve(let points): return Self.spline(points, subdivisions: max(16, segments))
        case .line(let s, let e): return [s, e]
        case .arc, .circle: return (0...segments).map { point(at: Double($0) / Double(segments)) }
        }
    }

    /// Returns geometry with handle `index` moved to `p` (endpoints; for arcs index 2 sets the bulge).
    public func movingHandle(_ index: Int, to p: Point2) -> FormGeometry {
        switch self {
        case .curve(var points):
            guard points.indices.contains(index) else { return self }
            points[index] = p
            return .curve(points: points)
        case .circle(let c, let r):
            return index == 0 ? .circle(center: p, radius: r) : .circle(center: c, radius: max(1e-6, c.distance(to: p)))
        case .line(let s, let e):
            return index == 0 ? .line(start: p, end: e) : .line(start: s, end: p)
        case .arc(let s, let e, let b):
            switch index {
            case 0: return .arc(start: p, end: e, bulge: b)
            case 1: return .arc(start: s, end: p, bulge: b)
            default:
                let left = (e - s).perpendicular.normalized
                return .arc(start: s, end: e, bulge: (p - s.lerp(to: e, 0.5)).dot(left))
            }
        }
    }
}

extension FormGeometry {
    /// Centripetal Catmull–Rom interpolation avoids loops between unevenly spaced points.
    private static func spline(_ points: [Point2], subdivisions: Int) -> [Point2] {
        var knots: [Point2] = []
        for point in points where knots.last.map({ $0.distance(to: point) > 1e-9 }) ?? true { knots.append(point) }
        guard knots.count > 2 else { return knots }
        var result = [knots[0]]
        for i in 0..<(knots.count - 1) {
            let p1 = knots[i], p2 = knots[i + 1]
            let p0 = i > 0 ? knots[i - 1] : p1 * 2 - p2
            let p3 = i + 2 < knots.count ? knots[i + 2] : p2 * 2 - p1
            let t0 = 0.0, t1 = p0.distance(to: p1).squareRoot()
            let t2 = t1 + p1.distance(to: p2).squareRoot()
            let t3 = t2 + p2.distance(to: p3).squareRoot()
            func blend(_ a: Point2, _ b: Point2, _ ta: Double, _ tb: Double, _ t: Double) -> Point2 {
                a * ((tb - t) / (tb - ta)) + b * ((t - ta) / (tb - ta))
            }
            for j in 1...subdivisions {
                let t = t1 + (t2 - t1) * Double(j) / Double(subdivisions)
                let a1 = blend(p0, p1, t0, t1, t), a2 = blend(p1, p2, t1, t2, t), a3 = blend(p2, p3, t2, t3, t)
                let b1 = blend(a1, a2, t0, t2, t), b2 = blend(a2, a3, t1, t3, t)
                result.append(blend(b1, b2, t1, t2, t))
            }
        }
        return result
    }

    private static func samplePolyline(_ samples: [Point2], at t: Double) -> Point2 {
        guard let first = samples.first else { return .zero }
        let lengths = zip(samples, samples.dropFirst()).map { $0.distance(to: $1) }
        var remaining = min(1, max(0, t)) * lengths.reduce(0, +)
        for (i, length) in lengths.enumerated() {
            if remaining <= length, length > 0 { return samples[i].lerp(to: samples[i + 1], remaining / length) }
            remaining -= length
        }
        return samples.last ?? first
    }
}
