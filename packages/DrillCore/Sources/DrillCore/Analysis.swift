import Foundation
import DrillTiming

/// A design-aid warning. Issues describe measurements against thresholds;
/// they never assert real-world safety.
public struct DrillIssue: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case unresolvedPosition
        case outOfBounds
        case largeStride
        case discontinuity
        case closePass

        public var title: String {
            switch self {
            case .unresolvedPosition: return "Missing position"
            case .outOfBounds: return "Outside field"
            case .largeStride: return "Large stride"
            case .discontinuity: return "Jump without counts"
            case .closePass: return "Close pass"
            }
        }
    }

    public var id: String { "\(kind.rawValue)|\(setID)|\(performers.map(\.description).joined(separator: ","))" }
    public var kind: Kind
    public var setID: SetID
    public var performers: [PerformerID]
    /// Count range the issue covers (the move into `setID`, or the arrival itself).
    public var pulseRange: ClosedRange<Double>
    public var measured: Double?
    public var threshold: Double?
    public var message: String
    /// True when the measurement comes from sampling a curved path rather than an exact solution.
    public var isSampled: Bool = false
}

/// One performer's travel through a move, as analysis sees it.
struct Mover {
    var id: PerformerID
    var start: Point2
    var end: Point2
    /// Nil for straight travel.
    var route: ResolvedPath?
    var counts: Double

    func point(at u: Double) -> Point2 {
        if let route { return route.point(at: u).point }
        return counts > 0 ? start.lerp(to: end, min(max(u / counts, 0), 1)) : end
    }

    var bounds: Rect2 {
        guard let route, let first = route.pieces.first?.bounds else { return Rect2(points: [start, end]) }
        return route.pieces.dropFirst().reduce(first) {
            let b = $1.bounds
            return Rect2(minX: min($0.minX, b.minX), minY: min($0.minY, b.minY), maxX: max($0.maxX, b.maxX), maxY: max($0.maxY, b.maxY))
        }
    }

    /// Counts into the move where the motion changes (segment joints), with 0 and the end.
    var breakpoints: [Double] {
        [0, counts] + (route?.pieces.map { $0.startCount.doubleValue } ?? [])
    }

    /// Whether the motion is linear in time on the interval starting at `u` (a hold or a line).
    func isLinear(at u: Double) -> Bool {
        guard let route else { return true }
        if case .arc = route.pieces[route.pieceIndex(at: u)].segment { return false }
        return true
    }
}

public enum DrillAnalyzer {
    /// Analyzes a movement: missing data, bounds (including where a path bulges),
    /// stride per count along each path segment, zero-count jumps and close passes
    /// between moving performers.
    public static func analyze(_ show: Show, movementID: MovementID, map: TimingMap? = nil) throws -> [DrillIssue] {
        let evaluator = try SceneEvaluator(show: show, movementID: movementID, map: map)
        let sets = evaluator.sets
        let pulses = evaluator.pulses
        let bounds = show.field.bounds
        let settings = show.analysis
        let step = show.field.stepSize
        var issues: [DrillIssue] = []
        let labels = Dictionary(uniqueKeysWithValues: show.performers.map { ($0.id, $0.label) })

        for (k, set) in sets.enumerated() {
            let formation = show.formation(set.id)
            let unresolved = show.performers.filter { formation[$0.id] == .unresolved }.map(\.id)
            if !unresolved.isEmpty {
                issues.append(DrillIssue(kind: .unresolvedPosition, setID: set.id, performers: unresolved, pulseRange: pulses[k]...pulses[k],
                                         measured: Double(unresolved.count), threshold: nil,
                                         message: "Set \(set.label): \(unresolved.count) performer\(unresolved.count == 1 ? "" : "s") without a position."))
            }
            for performer in show.performers {
                if let p = formation[performer.id].position, !bounds.contains(p.point, tolerance: 1e-6) {
                    issues.append(DrillIssue(kind: .outOfBounds, setID: set.id, performers: [performer.id], pulseRange: pulses[k]...pulses[k],
                                             measured: nil, threshold: nil, message: "Set \(set.label): \(performer.label) is outside the field."))
                }
            }
            guard k > 0 else { continue }
            let counts = pulses[k] - pulses[k - 1]
            let previous = show.formation(sets[k - 1].id)
            var movers: [Mover] = []
            for performer in show.performers {
                guard let a = previous[performer.id].position?.point, let b = formation[performer.id].position?.point else { continue }
                let distance = a.distance(to: b)
                let route = evaluator.route(into: k, performer: performer.id)
                let mover = Mover(id: performer.id, start: a, end: b, route: route, counts: counts)
                movers.append(mover)
                if let route {
                    let box = mover.bounds
                    if !bounds.contains(Point2(box.minX, box.minY), tolerance: 1e-6) || !bounds.contains(Point2(box.maxX, box.maxY), tolerance: 1e-6),
                       bounds.contains(a, tolerance: 1e-6), bounds.contains(b, tolerance: 1e-6) {
                        issues.append(DrillIssue(kind: .outOfBounds, setID: set.id, performers: [performer.id], pulseRange: pulses[k - 1]...pulses[k],
                                                 measured: nil, threshold: nil, message: "Move to set \(set.label): \(performer.label) leaves the field during the move."))
                    }
                    // A delayed start or early arrival makes the moving legs faster than the chord suggests.
                    guard let fastest = route.pieces.filter({ !$0.segment.isHold }).max(by: { $0.pace < $1.pace }) else { continue }
                    if fastest.pace > settings.maxStride + 1e-9 {
                        let range = (pulses[k - 1] + fastest.startCount.doubleValue)...(pulses[k - 1] + fastest.endCount.doubleValue)
                        let counts = "\(TimeFormat.decimal(fastest.startCount.doubleValue, places: 1))–\(TimeFormat.decimal(fastest.endCount.doubleValue, places: 1))"
                        issues.append(DrillIssue(kind: .largeStride, setID: set.id, performers: [performer.id], pulseRange: range,
                                                 measured: fastest.pace, threshold: settings.maxStride,
                                                 message: "Set \(set.label): \(performer.label) steps \(TimeFormat.decimal(stepsPerFiveYards(fastest.pace), places: 1)) to 5 (\(TimeFormat.decimal(fastest.pace / step, places: 2)) steps per count) on counts \(counts)."))
                    }
                    continue
                }
                if counts <= 1e-9 {
                    if distance > 1e-6 {
                        issues.append(DrillIssue(kind: .discontinuity, setID: set.id, performers: [performer.id], pulseRange: pulses[k - 1]...pulses[k],
                                                 measured: distance, threshold: 0, message: "Set \(set.label): \(performer.label) moves with no counts."))
                    }
                    continue
                }
                let stride = distance / counts
                if stride > settings.maxStride + 1e-9 {
                    issues.append(DrillIssue(kind: .largeStride, setID: set.id, performers: [performer.id], pulseRange: pulses[k - 1]...pulses[k],
                                             measured: stride, threshold: settings.maxStride,
                                             message: "Set \(set.label): \(performer.label) steps \(TimeFormat.decimal(stepsPerFiveYards(stride), places: 1)) to 5 (\(TimeFormat.decimal(stride / step, places: 2)) steps per count)."))
                }
            }
            issues += closePasses(movers, set: set, range: pulses[k - 1]...pulses[k], clearance: settings.minClearance, labels: labels)
        }
        return issues
    }

    /// Steps needed to cover five yards at this stride (8 = standard 8-to-5).
    public static func stepsPerFiveYards(_ strideMeters: Double) -> Double { strideMeters > 0 ? 5 * Field.yard / strideMeters : .infinity }

    /// Pairs whose paths come closer than `clearance` during the move and closer
    /// than at either arrival. Exact while both performers hold or travel straight;
    /// where an arc is involved the distance is sampled and refined, and the issue
    /// is marked as sampled.
    static func closePasses(_ movers: [Mover], set: ArrivalSet, range: ClosedRange<Double>, clearance: Double,
                            labels: [PerformerID: String]) -> [DrillIssue] {
        guard clearance > 0, movers.count > 1 else { return [] }
        // Broad phase: bin swept bounding boxes on a grid.
        let cell = max(clearance * 4, 2.0)
        var grid: [Int64: [Int]] = [:]
        var boxes: [Rect2] = []
        for (i, m) in movers.enumerated() {
            let box = m.bounds.insetBy(-clearance / 2)
            boxes.append(box)
            for gx in Int64((box.minX / cell).rounded(.down))...Int64((box.maxX / cell).rounded(.down)) {
                for gy in Int64((box.minY / cell).rounded(.down))...Int64((box.maxY / cell).rounded(.down)) {
                    grid[gx &* 1_000_003 &+ gy, default: []].append(i)
                }
            }
        }
        var seen = Set<Int64>()
        var issues: [DrillIssue] = []
        for bucket in grid.values where bucket.count > 1 {
            for a in 0..<bucket.count {
                for b in (a + 1)..<bucket.count {
                    let i = min(bucket[a], bucket[b]), j = max(bucket[a], bucket[b])
                    guard seen.insert(Int64(i) << 32 | Int64(j)).inserted, boxes[i].intersects(boxes[j]) else { continue }
                    let a = movers[i], b = movers[j]
                    let (closest, u, sampled) = closestApproach(a, b)
                    let endpoints = min(a.start.distance(to: b.start), a.end.distance(to: b.end))
                    if closest < clearance, closest < endpoints - 1e-6 {
                        let li = labels[a.id] ?? "?", lj = labels[b.id] ?? "?"
                        let pulse = range.lowerBound + u
                        let note = sampled ? " (sampled)" : ""
                        issues.append(DrillIssue(kind: .closePass, setID: set.id, performers: [a.id, b.id], pulseRange: range, measured: closest, threshold: clearance,
                                                 message: "Move to set \(set.label): \(li) and \(lj) pass \(TimeFormat.decimal(closest, places: 2)) m apart near count \(TimeFormat.decimal(pulse, places: 1))\(note).",
                                                 isSampled: sampled))
                    }
                }
            }
        }
        return issues.sorted { $0.message < $1.message }
    }

    /// Smallest distance between two movers during the move, the count it happens
    /// at, and whether it was sampled. The move is split at both performers'
    /// segment joints; pieces where both hold or travel straight are solved exactly.
    static func closestApproach(_ a: Mover, _ b: Mover) -> (distance: Double, count: Double, sampled: Bool) {
        let total = a.counts
        guard total > 0 else { return (a.end.distance(to: b.end), 0, false) }
        let cuts = Array(Set((a.breakpoints + b.breakpoints).map { min(max($0, 0), total) })).sorted()
        var best = (distance: Double.infinity, count: 0.0, sampled: false)
        func distance(_ u: Double) -> Double { a.point(at: u).distance(to: b.point(at: u)) }
        for (u0, u1) in zip(cuts, cuts.dropFirst()) where u1 - u0 > 1e-12 {
            if a.isLinear(at: u0), b.isLinear(at: u0) {
                // Relative motion is linear on this interval: minimize |d0 + dv·t| exactly.
                let d0 = a.point(at: u0) - b.point(at: u0)
                let dv = (a.point(at: u1) - b.point(at: u1)) - d0
                let vv = dv.dot(dv)
                let t = vv > 1e-12 ? min(max(-d0.dot(dv) / vv, 0), 1) : 0
                let d = (d0 + dv * t).length
                if d < best.distance { best = (d, u0 + (u1 - u0) * t, false) }
                continue
            }
            // At least 8 samples per count, then golden-section refinement around the smallest.
            let n = max(2, Int(((u1 - u0) * 8).rounded(.up)))
            var k = 0, smallest = Double.infinity
            for i in 0...n {
                let d = distance(u0 + (u1 - u0) * Double(i) / Double(n))
                if d < smallest { smallest = d; k = i }
            }
            var lo = u0 + (u1 - u0) * Double(max(k - 1, 0)) / Double(n)
            var hi = u0 + (u1 - u0) * Double(min(k + 1, n)) / Double(n)
            let ratio = (5.0.squareRoot() - 1) / 2
            for _ in 0..<60 where hi - lo > 1e-9 {
                let m1 = hi - (hi - lo) * ratio, m2 = lo + (hi - lo) * ratio
                if distance(m1) < distance(m2) { hi = m2 } else { lo = m1 }
            }
            let refined = (lo + hi) / 2
            let d = distance(refined)
            if d < smallest {
                if d < best.distance { best = (d, refined, true) }
            } else if smallest < best.distance {
                best = (smallest, u0 + (u1 - u0) * Double(k) / Double(n), true)
            }
        }
        return best
    }
}
