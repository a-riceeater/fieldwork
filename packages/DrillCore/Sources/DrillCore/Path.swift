import Foundation
import DrillTiming

/// One piece of a performer's route through a move. Durations are in count pulses,
/// the same parameter the straight model uses, so tempo never bends a path.
public enum PathSegment: Hashable, Codable, Sendable {
    /// Stand still (mark time) at the current point.
    case hold(counts: Rational)
    /// Straight leg at constant speed to `to`.
    case line(counts: Rational, to: Point2)
    /// Circular arc at constant speed to `to`, turning `sweep` degrees.
    /// Positive = clockwise seen from above, which bulges to the left of start→end,
    /// the same side as a positive `form.bulge`. 0 < |sweep| < 360.
    case arc(counts: Rational, to: Point2, sweep: Double)

    public var counts: Rational {
        switch self {
        case .hold(let c), .line(let c, _), .arc(let c, _, _): return c
        }
    }

    /// The segment's end point; nil for a hold, which ends where it starts.
    public var end: Point2? {
        switch self {
        case .hold: return nil
        case .line(_, let p), .arc(_, let p, _): return p
        }
    }

    public var isHold: Bool {
        if case .hold = self { return true }
        return false
    }

    public var kindName: String {
        switch self {
        case .hold: return "hold"
        case .line: return "line"
        case .arc: return "arc"
        }
    }

    public func withCounts(_ counts: Rational) -> PathSegment {
        switch self {
        case .hold: return .hold(counts: counts)
        case .line(_, let p): return .line(counts: counts, to: p)
        case .arc(_, let p, let s): return .arc(counts: counts, to: p, sweep: s)
        }
    }

    /// The same segment ending at `end`; a hold is unchanged.
    public func withEnd(_ end: Point2) -> PathSegment {
        switch self {
        case .hold: return self
        case .line(let c, _): return .line(counts: c, to: end)
        case .arc(let c, _, let s): return .arc(counts: c, to: end, sweep: s)
        }
    }
}

/// Circle through a segment's start and end, turning `sweep` (radians, + = clockwise).
public struct ArcGeometry: Hashable, Sendable {
    public var center: Point2
    public var radius: Double
    /// Angle of the start point around the center, radians, counter-clockwise from +x.
    public var startAngle: Double
    /// Signed turn in radians; positive is clockwise, so the angle decreases.
    public var sweep: Double
    public var start: Point2
    public var end: Point2

    /// Nil when the chord is too short to define a circle.
    public init?(from p0: Point2, to p1: Point2, sweepDegrees: Double) {
        let c = p1 - p0
        let length = c.length
        let theta = sweepDegrees * .pi / 180
        guard length > 1e-12, theta.isFinite, abs(theta) > 0 else { return nil }
        let mid = (p0 + p1) / 2
        let left = Point2(-c.y, c.x) / length
        let h = (length / 2) / tan(theta / 2)
        center = mid - left * h
        radius = p0.distance(to: center)
        startAngle = atan2(p0.y - center.y, p0.x - center.x)
        sweep = theta
        start = p0
        end = p1
    }

    /// Point at fraction `s` of the sweep; exactly the end point at `s = 1`.
    public func point(_ s: Double) -> Point2 {
        if s >= 1 { return end }
        if s <= 0 { return start }
        let a = startAngle - sweep * s
        return Point2(center.x + radius * cos(a), center.y + radius * sin(a))
    }

    public var length: Double { radius * abs(sweep) }

    /// Tight bounding box: the endpoints plus every axis extreme the arc crosses.
    public var bounds: Rect2 {
        var points = [start, end]
        for k in 0..<4 {
            let axis = Double(k) * .pi / 2
            // Fraction of the sweep at which the angle reaches `axis` (mod 2π), if within the arc.
            var d = (startAngle - axis) / sweep
            let period = 2 * .pi / abs(sweep)
            d = d.truncatingRemainder(dividingBy: period)
            if d < 0 { d += period }
            if d <= 1 { points.append(point(d)) }
        }
        return Rect2(points: points)
    }
}

/// A segment resolved against its start point and start count.
public struct PathPiece: Hashable, Sendable {
    public var segment: PathSegment
    public var index: Int
    public var start: Point2
    public var end: Point2
    /// Counts into the move where the segment starts.
    public var startCount: Rational
    public var arc: ArcGeometry?

    public var counts: Rational { segment.counts }
    public var endCount: Rational { startCount + segment.counts }

    /// Distance traveled along the segment, meters.
    public var length: Double {
        switch segment {
        case .hold: return 0
        case .line: return start.distance(to: end)
        case .arc: return arc?.length ?? start.distance(to: end)
        }
    }

    /// Distance per count, meters.
    public var pace: Double { counts.isZero ? 0 : length / counts.doubleValue }

    public func point(_ s: Double) -> Point2 {
        switch segment {
        case .hold: return start
        case .line:
            if s >= 1 { return end }
            return start.lerp(to: end, max(s, 0))
        case .arc: return arc?.point(s) ?? start.lerp(to: end, min(max(s, 0), 1))
        }
    }

    public var bounds: Rect2 {
        if let arc { return arc.bounds }
        return Rect2(points: [start, end])
    }

    /// Sagitta (signed bulge to the left of start→end) of an arc piece; 0 for others.
    public var sagitta: Double {
        guard case .arc(_, _, let sweep) = segment else { return 0 }
        return PerformerPath.sagitta(chord: start.distance(to: end), sweepDegrees: sweep)
    }
}

/// The route one performer takes through one move. The start is implicit (the
/// placement at the previous set); the end is the last line or arc's end.
public struct PerformerPath: Hashable, Codable, Sendable {
    public var segments: [PathSegment]

    public init(_ segments: [PathSegment]) { self.segments = segments }

    public static let pointTolerance = 1e-9
    public static let angleTolerance = 1e-9
    /// Arcs flatter than this become lines.
    public static let minimumSagitta = 1e-6
    /// Arcs need a chord longer than this.
    public static let minimumChord = 1e-6

    public var totalCounts: Rational { segments.reduce(Rational.zero) { $0 + $1.counts } }

    public var hasMovement: Bool { segments.contains { !$0.isHold } }

    public func end(from start: Point2) -> Point2 {
        segments.last(where: { !$0.isHold })?.end ?? start
    }

    public func pieces(from start: Point2) -> [PathPiece] {
        var result: [PathPiece] = []
        result.reserveCapacity(segments.count)
        var point = start
        var count = Rational.zero
        for (i, segment) in segments.enumerated() {
            let end = segment.end ?? point
            var arc: ArcGeometry?
            if case .arc(_, let to, let sweep) = segment { arc = ArcGeometry(from: point, to: to, sweepDegrees: sweep) }
            result.append(PathPiece(segment: segment, index: i, start: point, end: end, startCount: count, arc: arc))
            point = end
            count += segment.counts
        }
        return result
    }

    public func length(from start: Point2) -> Double { pieces(from: start).reduce(0) { $0 + $1.length } }

    public func bounds(from start: Point2) -> Rect2 {
        let boxes = pieces(from: start).map(\.bounds)
        guard let first = boxes.first else { return Rect2(points: [start]) }
        return boxes.dropFirst().reduce(first) {
            Rect2(minX: min($0.minX, $1.minX), minY: min($0.minY, $1.minY), maxX: max($0.maxX, $1.maxX), maxY: max($0.maxY, $1.maxY))
        }
    }

    /// Position `u` counts into the move. A boundary belongs to the later segment.
    public func point(at u: Double, from start: Point2) -> (point: Point2, isMoving: Bool) {
        ResolvedPath(self, from: start).point(at: u)
    }

    /// Sagitta of a circular arc with this chord and sweep (signed like the sweep).
    public static func sagitta(chord: Double, sweepDegrees: Double) -> Double {
        (chord / 2) * tan(sweepDegrees * .pi / 180 / 4)
    }

    /// Sweep in degrees of the arc with this chord and signed sagitta.
    public static func sweep(chord: Double, sagitta: Double) -> Double {
        guard chord > 0 else { return 0 }
        return 4 * atan(2 * sagitta / chord) * 180 / .pi
    }

    // MARK: Editing operations (all exact in counts)

    /// Every segment's counts multiplied by `factor`, as when a move is stretched.
    public func scaled(by factor: Rational) -> PerformerPath {
        PerformerPath(segments.map { $0.withCounts($0.counts * factor) })
    }

    /// The last line or arc ends at `end`; an arc keeps its sweep.
    public func movingEnd(to end: Point2) -> PerformerPath {
        guard let i = segments.lastIndex(where: { !$0.isHold }) else { return self }
        var copy = self
        copy.segments[i] = segments[i].withEnd(end)
        return copy
    }

    /// Cuts the path `u` counts into the move. A line splits at the point, an arc
    /// splits its sweep in proportion and a hold splits its counts. Both parts are
    /// raw (not normalized); the cut point is `point`.
    public func split(at u: Rational, from start: Point2) -> (left: [PathSegment], right: [PathSegment], point: Point2) {
        var left: [PathSegment] = []
        var right: [PathSegment] = []
        var cut = start
        for piece in pieces(from: start) {
            if piece.endCount <= u {
                left.append(piece.segment)
                cut = piece.end
            } else if piece.startCount >= u {
                right.append(piece.segment)
            } else {
                let a = u - piece.startCount, b = piece.endCount - u
                let s = (a / piece.counts).doubleValue
                let p = piece.point(s)
                cut = p
                switch piece.segment {
                case .hold:
                    left.append(.hold(counts: a)); right.append(.hold(counts: b))
                case .line(_, let to):
                    left.append(.line(counts: a, to: p)); right.append(.line(counts: b, to: to))
                case .arc(_, let to, let sweep):
                    left.append(.arc(counts: a, to: p, sweep: sweep * s)); right.append(.arc(counts: b, to: to, sweep: sweep * (1 - s)))
                }
            }
        }
        return (left, right, cut)
    }

    /// Canonical form of a route from `start` to `end`, or nil when it is one
    /// straight line over the whole move or a single hold (start = end).
    ///
    /// Zero-length lines become holds and adjacent holds merge; flat or chordless
    /// arcs become lines; adjacent lines in one direction at one pace merge, and so
    /// do adjacent arcs on one circle at one angular pace.
    public static func canonical(_ input: [PathSegment], from start: Point2, to end: Point2) -> PerformerPath? {
        var out: [PathSegment] = []
        var starts: [Point2] = []
        var point = start
        for segment in input where segment.counts > .zero {
            var seg = segment
            if case .arc(let c, let to, let sweep) = seg {
                let chord = point.distance(to: to)
                if chord <= minimumChord || abs(sagitta(chord: chord, sweepDegrees: sweep)) < minimumSagitta {
                    seg = .line(counts: c, to: to)
                }
            }
            if case .line(let c, let to) = seg, point.distance(to: to) <= pointTolerance { seg = .hold(counts: c) }
            if let last = out.last, let lastStart = starts.last, let merged = merge(last, from: lastStart, with: seg) {
                out[out.count - 1] = merged
            } else {
                out.append(seg)
                starts.append(point)
            }
            point = seg.end ?? point
        }
        // A route that is one straight line, or that never moves, is stored as no path.
        let moving = out.filter { !$0.isHold }
        if moving.isEmpty, start.distance(to: end) <= pointTolerance { return nil }
        if out.count == 1, case .line(_, let to) = out[0], to == end { return nil }
        return PerformerPath(out)
    }

    static func merge(_ a: PathSegment, from aStart: Point2, with b: PathSegment) -> PathSegment? {
        switch (a, b) {
        case (.hold(let c1), .hold(let c2)):
            return .hold(counts: c1 + c2)
        case (.line(let c1, let p1), .line(let c2, let p2)):
            let v1 = (p1 - aStart) / c1.doubleValue, v2 = (p2 - p1) / c2.doubleValue
            let l1 = v1.length, l2 = v2.length
            guard abs(l1 - l2) <= pointTolerance, l1 > 0, l2 > 0 else { return nil }
            let cross = v1.x * v2.y - v1.y * v2.x
            guard abs(cross) / (l1 * l2) <= angleTolerance, v1.dot(v2) > 0 else { return nil }
            return .line(counts: c1 + c2, to: p2)
        case (.arc(let c1, let p1, let s1), .arc(let c2, let p2, let s2)):
            guard let g1 = ArcGeometry(from: aStart, to: p1, sweepDegrees: s1), let g2 = ArcGeometry(from: p1, to: p2, sweepDegrees: s2) else { return nil }
            let w1 = g1.sweep / c1.doubleValue, w2 = g2.sweep / c2.doubleValue
            guard g1.center.distance(to: g2.center) <= pointTolerance, abs(g1.radius - g2.radius) <= pointTolerance,
                  abs(w1 - w2) <= angleTolerance, abs(s1 + s2) < 360 else { return nil }
            return .arc(counts: c1 + c2, to: p2, sweep: s1 + s2)
        default:
            return nil
        }
    }
}

/// A path with its pieces resolved once, for evaluating many frames.
public struct ResolvedPath: Hashable, Sendable {
    public let pieces: [PathPiece]
    let starts: [Double]
    let total: Double

    public init(_ path: PerformerPath, from start: Point2) {
        pieces = path.pieces(from: start)
        starts = pieces.map { $0.startCount.doubleValue }
        total = path.totalCounts.doubleValue
    }

    /// Index of the piece containing `u`; a boundary belongs to the later piece.
    public func pieceIndex(at u: Double) -> Int {
        var lo = 0, hi = pieces.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= u { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func point(at u: Double) -> (point: Point2, isMoving: Bool) {
        guard !pieces.isEmpty else { return (.zero, false) }
        let u = min(max(u, 0), total)
        let piece = pieces[pieceIndex(at: u)]
        let span = piece.counts.doubleValue
        let s = span > 0 ? (u - starts[piece.index]) / span : 1
        return (piece.point(s), !piece.segment.isHold)
    }
}

extension Show {
    /// The path a performer follows in the move into a set, if not straight.
    public func path(into setID: SetID, performer: PerformerID) -> PerformerPath? {
        transition(into: setID)?.paths[performer]
    }

    /// Number of performer paths across every move.
    public var pathCount: Int { transitions.reduce(0) { $0 + $1.paths.count } }

    /// Number of stored segments across every path.
    public var pathSegmentCount: Int { transitions.reduce(0) { $0 + $1.paths.values.reduce(0) { $0 + $1.segments.count } } }
}
