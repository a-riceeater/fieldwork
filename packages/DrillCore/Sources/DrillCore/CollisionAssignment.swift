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
        var active = order.indices.map { routes(order[$0], $0) }
        for _ in 0..<4 {
            var changed = false
            for i in 0..<n {
                let own = (0..<n).filter { $0 != i }.reduce(fixedRisk(active[i])) { $0 + pair(active[i], active[$1]) }
                guard own.passes > 0 else { continue }
                var best: Int?, bestDelta = AssignmentRisk(), bestTravel = 0.0
                // Try shorter adjacent-move routes first. A swap eliminating
                // every affected close pass can stop the search immediately.
                func adjacentTravel(_ member: Int, _ dot: Int) -> Double {
                    moves.reduce(0) { total, move in
                        total + (move.other[members[member]].position?.point.distance(to: targets[dot]) ?? 0)
                    }
                }
                var candidates: [(index: Int, cost: Double)] = []
                for j in 0..<n where j != i {
                    let cost = adjacentTravel(order[j], i) + adjacentTravel(order[i], j)
                    candidates.append((j, cost))
                }
                candidates.sort { a, b in a.cost == b.cost ? a.index < b.index : a.cost < b.cost }
                for candidate in candidates {
                    let j = candidate.index
                    let left = routes(order[j], i), right = routes(order[i], j)
                    var before = fixedRisk(active[i]) + fixedRisk(active[j]) + pair(active[i], active[j])
                    var after = fixedRisk(left) + fixedRisk(right) + pair(left, right)
                    for k in 0..<n where k != i && k != j {
                        before = before + pair(active[i], active[k]) + pair(active[j], active[k])
                        after = after + pair(left, active[k]) + pair(right, active[k])
                    }
                    let delta = AssignmentRisk(passes: after.passes - before.passes, deficit: after.deficit - before.deficit)
                    let distance = travel(order[j], i) + travel(order[i], j) - travel(order[i], i) - travel(order[j], j)
                    let tied = delta.passes == bestDelta.passes && abs(delta.deficit - bestDelta.deficit) <= 1e-9
                    if delta.improves(on: bestDelta) || (tied && distance < bestTravel - 1e-9) {
                        best = j; bestDelta = delta; bestTravel = distance
                        if after.passes == 0 && delta.passes < 0 { break }
                    }
                }
                if let j = best {
                    order.swapAt(i, j)
                    active[i] = routes(order[i], i)
                    active[j] = routes(order[j], j)
                    changed = true
                }
            }
            if !changed { break }
        }
        return order.map { members[$0] }
    }
}
