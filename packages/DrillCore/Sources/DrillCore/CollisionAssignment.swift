import Foundation

/// One adjacent move as it would play after assigning new dots at the edited set.
private struct AssignmentMove {
    var incoming: Bool
    var other: Formation
    var paths: [PerformerID: PerformerPath]
    var counts: Double
    var fixed: [Mover]

    func mover(_ id: PerformerID, at dot: Point2) -> Mover? {
        guard let point = other[id].position?.point else { return nil }
        let start = incoming ? point : dot, end = incoming ? dot : point
        // This is the same endpoint adjustment and canonicalization performed
        // by reconcilePaths when the actual placement command is committed.
        let path = paths[id].flatMap {
            PerformerPath.canonical($0.movingEnd(to: end).segments, from: start, to: end)
        }
        return Mover(id: id, start: start, end: end,
                     route: path.map { ResolvedPath($0, from: start) }, counts: counts)
    }
}

private struct AssignmentRisk {
    var passes = 0
    var deficit = 0.0

    static func + (a: Self, b: Self) -> Self {
        Self(passes: a.passes + b.passes, deficit: a.deficit + b.deficit)
    }

    func improves(on other: Self) -> Bool {
        passes < other.passes || (passes == other.passes && deficit < other.deficit - 1e-9)
    }
}

extension Show {
    /// Refines the distance matching with deterministic, bounded pair swaps.
    /// Close-pass count wins first, then clearance deficit, then travel distance.
    /// This is a local improvement, not a proof of collision-free choreography.
    func collisionAwareOrder(_ members: [PerformerID], to targets: [Point2], at setID: SetID) -> [PerformerID] {
        let clearance = analysis.minClearance
        guard members.count > 1, clearance.isFinite, clearance > 0 else { return members }
        let selected = Set(members), current = formation(setID)
        var moves: [AssignmentMove] = []
        for arrival in [set(setID), nextSet(after: setID)].compactMap({ $0 }) {
            guard let move = try? move(into: arrival.id), move.counts > .zero else { continue }
            let incoming = arrival.id == setID
            let other = formation(incoming ? move.from.id : arrival.id)
            var context = AssignmentMove(incoming: incoming, other: other, paths: move.transition.paths,
                                         counts: move.counts.doubleValue, fixed: [])
            context.fixed = performers.filter { !selected.contains($0.id) }.compactMap {
                guard let point = current[$0.id].position?.point else { return nil }
                return context.mover($0.id, at: point)
            }
            moves.append(context)
        }
        guard !moves.isEmpty else { return members }
        let n = members.count
        var order = Array(0..<n)
        var cache: [Int: [Mover?]] = [:]
        func routes(_ member: Int, _ dot: Int) -> [Mover?] {
            let key = member * n + dot
            if let value = cache[key] { return value }
            let value = moves.map { $0.mover(members[member], at: targets[dot]) }
            cache[key] = value
            return value
        }
        func risk(_ a: Mover?, _ b: Mover?) -> AssignmentRisk {
            guard let a, let b, a.bounds.insetBy(-clearance).intersects(b.bounds) else { return AssignmentRisk() }
            let distance = DrillAnalyzer.closestApproach(a, b).distance
            let endpoints = min(a.start.distance(to: b.start), a.end.distance(to: b.end))
            // Match the analyzer: a close arrival alone is not a mid-move pass.
            guard distance < clearance, distance < endpoints - 1e-6 else { return AssignmentRisk() }
            return AssignmentRisk(passes: 1, deficit: clearance - distance)
        }
        func pair(_ a: [Mover?], _ b: [Mover?]) -> AssignmentRisk {
            zip(a, b).reduce(AssignmentRisk()) { $0 + risk($1.0, $1.1) }
        }
        func fixedRisk(_ route: [Mover?]) -> AssignmentRisk {
            moves.indices.reduce(AssignmentRisk()) { total, k in
                moves[k].fixed.reduce(total) { $0 + risk(route[k], $1) }
            }
        }
        let previous = previousSet(before: setID).map { formation($0.id) }
        func travel(_ member: Int, _ dot: Int) -> Double {
            let id = members[member]
            let source = current[id].position ?? (current[id] == .unresolved ? previous?[id].position : nil)
            return source?.point.distance(to: targets[dot]) ?? 0
        }
