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
}

public enum DrillAnalyzer {
    /// Analyzes a movement: missing data, bounds, stride per count along the
    /// straight path, zero-count jumps and close passes between moving performers.
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
            var movers: [(PerformerID, Point2, Point2)] = []
            for performer in show.performers {
                guard let a = previous[performer.id].position?.point, let b = formation[performer.id].position?.point else { continue }
                let distance = a.distance(to: b)
                movers.append((performer.id, a, b))
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

    /// Pairs whose straight-line paths come closer than `clearance` during the move
    /// and closer than at either arrival. Exact for linear motion over a shared interval.
    static func closePasses(_ movers: [(PerformerID, Point2, Point2)], set: ArrivalSet, range: ClosedRange<Double>, clearance: Double,
                            labels: [PerformerID: String]) -> [DrillIssue] {
        guard clearance > 0, movers.count > 1 else { return [] }
        // Broad phase: bin swept bounding boxes on a grid.
        let cell = max(clearance * 4, 2.0)
        var grid: [Int64: [Int]] = [:]
        var boxes: [Rect2] = []
        for (i, m) in movers.enumerated() {
            let box = Rect2(points: [m.1, m.2]).insetBy(-clearance / 2)
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
                    let (pi, a0, a1) = movers[i], (pj, b0, b1) = movers[j]
                    let d0 = a0 - b0
                    let dv = (a1 - a0) - (b1 - b0)
                    let vv = dv.dot(dv)
                    let t = vv > 1e-12 ? min(max(-d0.dot(dv) / vv, 0), 1) : 0
                    let closest = (d0 + dv * t).length
                    let endpoints = min(d0.length, (a1 - b1).length)
                    if closest < clearance, closest < endpoints - 1e-6 {
                        let li = labels[pi] ?? "?", lj = labels[pj] ?? "?"
                        let pulse = range.lowerBound + (range.upperBound - range.lowerBound) * t
                        issues.append(DrillIssue(kind: .closePass, setID: set.id, performers: [pi, pj], pulseRange: range, measured: closest, threshold: clearance,
                                                 message: "Move to set \(set.label): \(li) and \(lj) pass \(TimeFormat.decimal(closest, places: 2)) m apart near count \(TimeFormat.decimal(pulse, places: 1))."))
                    }
                }
            }
        }
        return issues.sorted { $0.message < $1.message }
    }
}
