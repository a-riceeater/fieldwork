import Foundation
import DrillTiming

/// One performer in an evaluated frame.
public struct EvaluatedPerformer: Hashable, Sendable {
    public enum State: Hashable, Sendable { case placed, unresolved, inactive }
    public var id: PerformerID
    public var x: Double
    public var y: Double
    public var z: Double
    public var facing: Double
    public var state: State
    public var isMoving: Bool
}

/// Immutable result of evaluating a movement at one count position. Both the
/// 2D canvases and a future 3D renderer consume this same contract.
public struct SceneSnapshot: Sendable {
    public var pulse: Double
    /// Index of the last set at or before `pulse`.
    public var setIndex: Int
    /// Index of the set being moved into, if between sets.
    public var nextSetIndex: Int?
    /// Progress through the current move, 0...1.
    public var progress: Double
    public var performers: [EvaluatedPerformer]
}

/// Evaluates audio time → cursor → count → transition progress → world positions.
public struct SceneEvaluator: Sendable {
    public let show: Show
    public let movementID: MovementID
    public let map: TimingMap
    public let sets: [ArrivalSet]
    public let pulses: [Double]
    private let formations: [[PerformerID: Placement]]

    public init(show: Show, movementID: MovementID, map: TimingMap? = nil) throws {
        self.show = show
        self.movementID = movementID
        let map = try map ?? show.timingMap(for: movementID)
        self.map = map
        let keyed = try show.setPulses(in: movementID, map: map)
        sets = keyed.map(\.set)
        pulses = keyed.map { $0.pulse.doubleValue }
        formations = sets.map { show.formation($0.id).placements }
    }

    public func pulse(of setID: SetID) -> Double? {
        sets.firstIndex { $0.id == setID }.map { pulses[$0] }
    }

    /// Index of the last set whose arrival is at or before `pulse`.
    public func setIndex(atPulse pulse: Double) -> Int {
        var lo = 0, hi = pulses.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pulses[mid] <= pulse + 1e-9 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func evaluate(audioTime: Double) -> SceneSnapshot {
        evaluate(pulse: map.locate(audioTime: audioTime).pulse)
    }

    public func evaluate(pulse: Double) -> SceneSnapshot {
        let k = setIndex(atPulse: pulse)
        let hasNext = k + 1 < sets.count && pulse > pulses[k] + 1e-9
        let progress: Double
        if hasNext {
            let span = pulses[k + 1] - pulses[k]
            progress = span > 0 ? min(max((pulse - pulses[k]) / span, 0), 1) : 1
        } else {
            progress = 0
        }
        var result: [EvaluatedPerformer] = []
        result.reserveCapacity(show.performers.count)
        let from = formations[k]
        let to = hasNext ? formations[k + 1] : [:]
        for performer in show.performers {
            let a = from[performer.id] ?? .unresolved
            if !hasNext {
                result.append(SceneEvaluator.performer(performer.id, a))
                continue
            }
            let b = to[performer.id] ?? .unresolved
            switch (a, b) {
            case (.placed(let p), .placed(let q)):
                let t = progress
                let facing = SceneEvaluator.interpolateAngle(p.facing, q.facing, t)
                let moving = p.point.distance(to: q.point) > 1e-9
                result.append(EvaluatedPerformer(id: performer.id, x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t, z: p.z + (q.z - p.z) * t,
                                                 facing: facing, state: .placed, isMoving: moving))
            case (.inactive, _), (_, .inactive):
                result.append(EvaluatedPerformer(id: performer.id, x: 0, y: 0, z: 0, facing: 0, state: .inactive, isMoving: false))
            default:
                result.append(EvaluatedPerformer(id: performer.id, x: 0, y: 0, z: 0, facing: 0, state: .unresolved, isMoving: false))
            }
        }
        return SceneSnapshot(pulse: pulse, setIndex: k, nextSetIndex: hasNext ? k + 1 : nil, progress: progress, performers: result)
    }

    static func performer(_ id: PerformerID, _ placement: Placement) -> EvaluatedPerformer {
        switch placement {
        case .placed(let p): return EvaluatedPerformer(id: id, x: p.x, y: p.y, z: p.z, facing: p.facing, state: .placed, isMoving: false)
        case .unresolved: return EvaluatedPerformer(id: id, x: 0, y: 0, z: 0, facing: 0, state: .unresolved, isMoving: false)
        case .inactive: return EvaluatedPerformer(id: id, x: 0, y: 0, z: 0, facing: 0, state: .inactive, isMoving: false)
        }
    }

    /// Shortest-arc interpolation of facing in degrees.
    static func interpolateAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        var r = (a + d * t).truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        return r
    }
}
