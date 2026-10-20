import Foundation

/// One adjacent move as it would play after assigning new dots at the edited set.
private struct AssignmentMove {
    var incoming: Bool
    var other: Formation
    var paths: [PerformerID: PerformerPath]
    var counts: Double
    var maxStride: Double

    func route(_ id: PerformerID, at dot: Point2) -> AssignmentRoute? {
        guard let point = other[id].position?.point else { return nil }
        let start = incoming ? point : dot, end = incoming ? dot : point
        // This is the same endpoint adjustment and canonicalization performed
        // by reconcilePaths when the actual placement command is committed.
        let path = paths[id].flatMap {
            PerformerPath.canonical($0.movingEnd(to: end).segments, from: start, to: end)
        }
        let mover = Mover(id: id, start: start, end: end,
                          route: path.map { ResolvedPath($0, from: start) }, counts: counts)
        // Match the analyzer's stride rule: the fastest leg of a path, else the chord.
        let pace = mover.route.map { $0.pieces.filter { !$0.segment.isHold }.map(\.pace).max() ?? 0 }
            ?? start.distance(to: end) / counts
        return AssignmentRoute(mover: mover, box: mover.bounds, overstride: pace > maxStride + 1e-9)
    }
}

/// A candidate move with the values the search reads repeatedly.
private struct AssignmentRoute {
    var mover: Mover
    var box: Rect2
    var overstride: Bool
}

private struct AssignmentRisk {
    var passes = 0
    var deficit = 0.0

    static func + (a: Self, b: Self) -> Self {
        Self(passes: a.passes + b.passes, deficit: a.deficit + b.deficit)
    }

    static func - (a: Self, b: Self) -> Self {
        Self(passes: a.passes - b.passes, deficit: a.deficit - b.deficit)
    }
}

/// Change made by one swap. Warnings (close passes plus large strides) win
/// first, then clearance deficit, then squared travel.
private struct SwapDelta {
    var warnings = 0
    var deficit = 0.0
    var travel = 0.0

    func improves(on other: Self) -> Bool {
        if warnings != other.warnings { return warnings < other.warnings }
        if abs(deficit - other.deficit) > 1e-9 { return deficit < other.deficit }
        return travel < other.travel - 1e-9
    }
}

/// Uniform grid over swept bounds: the broad phase for the swap search.
/// Bounds spanning too many cells (or non-finite ones) are kept in a list
/// that every query visits, so a stray far-off position cannot stall it.
private struct BoxGrid {
    let cell: Double
    private var buckets: [Int64: [Int]] = [:]
    private var oversized: [Int] = []

    init(cell: Double) { self.cell = cell }

    private func cells(_ box: Rect2) -> (x: ClosedRange<Int64>, y: ClosedRange<Int64>)? {
        let x0 = (box.minX / cell).rounded(.down), x1 = (box.maxX / cell).rounded(.down)
        let y0 = (box.minY / cell).rounded(.down), y1 = (box.maxY / cell).rounded(.down)
        let count = (x1 - x0 + 1) * (y1 - y0 + 1)
        guard count.isFinite, count <= 1024 else { return nil }
        return (Int64(x0)...Int64(x1), Int64(y0)...Int64(y1))
    }

    mutating func insert(_ item: Int, _ box: Rect2) {
        guard let (xs, ys) = cells(box) else { return oversized.append(item) }
        for x in xs { for y in ys { buckets[x &* 1_000_003 &+ y, default: []].append(item) } }
    }

    mutating func remove(_ item: Int, _ box: Rect2) {
        guard let (xs, ys) = cells(box) else { return oversized.removeAll { $0 == item } }
        for x in xs { for y in ys { buckets[x &* 1_000_003 &+ y]?.removeAll { $0 == item } } }
    }

    /// Items whose cells overlap `box`; an item can repeat across cells.
    func forEach(in box: Rect2, _ body: (Int) -> Void) {
        oversized.forEach(body)
        guard let (xs, ys) = cells(box) else { return buckets.values.joined().forEach(body) }
        for x in xs { for y in ys { buckets[x &* 1_000_003 &+ y]?.forEach(body) } }
    }
}

extension Show {
    /// Refines the squared-distance matching with deterministic, bounded pair
    /// swaps between nearby dots and between performers whose moves conflict.
    /// Close passes and large strides win first, then clearance deficit, then
    /// travel. This is a local improvement, not a proof of collision-free choreography.
    func collisionAwareOrder(_ members: [PerformerID], to targets: [Point2], at setID: SetID, workLimit: Int = 500_000) -> [PerformerID] {
        let clearance = analysis.minClearance
        guard members.count > 1, clearance.isFinite, clearance > 0,
              targets.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return members }
        let selected = Set(members), current = formation(setID)
        var moves: [AssignmentMove] = []
        var fixed: [[AssignmentRoute]] = []
        for arrival in [set(setID), nextSet(after: setID)].compactMap({ $0 }) {
            guard let move = try? move(into: arrival.id), move.counts > .zero else { continue }
            let incoming = arrival.id == setID
            let context = AssignmentMove(incoming: incoming, other: formation(incoming ? move.from.id : arrival.id),
                                         paths: move.transition.paths, counts: move.counts.doubleValue,
                                         maxStride: analysis.maxStride)
            moves.append(context)
            fixed.append(performers.filter { !selected.contains($0.id) }.compactMap {
                guard let point = current[$0.id].position?.point else { return nil }
                return context.route($0.id, at: point)
            })
        }
        guard !moves.isEmpty else { return members }
        let n = members.count
        var order = Array(0..<n)
        var cache = [[AssignmentRoute?]?](repeating: nil, count: n * n)
        func routes(_ member: Int, _ dot: Int) -> [AssignmentRoute?] {
            if let value = cache[member * n + dot] { return value }
            let value = moves.map { $0.route(members[member], at: targets[dot]) }
            cache[member * n + dot] = value
            return value
        }
        // Charge each narrow-phase candidate as well as arc samples/refinement.
        // Exhaustion discards an unfinished candidate, retaining the last fully scored order.
        var workRemaining = max(0, workLimit)
        var exhausted = false
        func risk(_ a: AssignmentRoute?, _ b: AssignmentRoute?) -> AssignmentRisk {
            guard !exhausted, !Task.isCancelled, workRemaining > 0 else {
                exhausted = true
                return AssignmentRisk()
            }
            workRemaining -= 1
            guard let a, let b, a.box.insetBy(-clearance).intersects(b.box) else { return AssignmentRisk() }
            if a.mover.route != nil || b.mover.route != nil {
                let pieces = (a.mover.route?.pieces.count ?? 1) + (b.mover.route?.pieces.count ?? 1)
                let estimate = ceil(max(a.mover.counts, b.mover.counts) * 8) + Double(pieces) * 244
                guard estimate.isFinite, estimate < Double(workRemaining) else {
                    exhausted = true
                    return AssignmentRisk()
                }
                workRemaining -= Int(estimate)
            }
            let distance = DrillAnalyzer.closestApproach(a.mover, b.mover).distance
            let endpoints = min(a.mover.start.distance(to: b.mover.start), a.mover.end.distance(to: b.mover.end))
            // Match the analyzer: a close arrival alone is not a mid-move pass.
            guard distance < clearance, distance < endpoints - 1e-6 else { return AssignmentRisk() }
            return AssignmentRisk(passes: 1, deficit: clearance - distance)
        }

        // Size grid cells to the typical swept extent so long moves span few cells.
        var extents: [Double] = []
        for k in moves.indices {
            extents += fixed[k].map { max($0.box.width, $0.box.height) }
            extents += (0..<n).compactMap { routes($0, $0)[k].map { max($0.box.width, $0.box.height) } }
        }
        extents.sort()
        let median = extents.isEmpty ? 0 : extents[extents.count / 2]
        let cell = max(clearance * 4, 2, median.isFinite ? median / 2 : 2)
        let fixedGrids = moves.indices.map { k in
            fixed[k].indices.reduce(into: BoxGrid(cell: cell)) { $0.insert($1, fixed[k][$1].box) }
        }
        var activeGrids = moves.indices.map { _ in BoxGrid(cell: cell) }
        var active = (0..<n).map { routes(order[$0], $0) }
        for i in 0..<n {
            for k in moves.indices { if let box = active[i][k]?.box { activeGrids[k].insert(i, box) } }
        }

        // Each conflicting dot's nearest other dots: the usual swap partners.
        let nearestCount = min(n - 1, 12)
        var nearestCache = [[Int]?](repeating: nil, count: n)
        func nearest(_ i: Int) -> [Int] {
            if let value = nearestCache[i] { return value }
            let others: [(index: Int, distance: Double)] = (0..<n).filter { $0 != i }.map { j in
                let d = targets[i] - targets[j]
                return (j, d.dot(d))
            }
            let sorted = others.sorted { $0.distance == $1.distance ? $0.index < $1.index : $0.distance < $1.distance }
            let value = sorted.prefix(nearestCount).map(\.index)
            nearestCache[i] = value
            return value
        }

        var fixedCache = [AssignmentRisk?](repeating: nil, count: n * n)
        func fixedRisk(_ member: Int, _ dot: Int) -> AssignmentRisk {
            if let value = fixedCache[member * n + dot] { return value }
            let route = routes(member, dot)
            var value = AssignmentRisk()
            for k in moves.indices {
                guard let r = route[k] else { continue }
                var seen = Set<Int>()
                fixedGrids[k].forEach(in: r.box.insetBy(-clearance)) { f in
                    guard !exhausted, seen.insert(f).inserted else { return }
                    value = value + risk(r, fixed[k][f])
                }
                if exhausted { return value }
            }
            fixedCache[member * n + dot] = value
            return value
        }
        /// Risk of `route` against the active moves of every dot except `excluded`.
        func activeRisk(_ route: [AssignmentRoute?], excluding excluded: (Int, Int), into rows: inout [Int: AssignmentRisk]) {
            for k in moves.indices {
                guard let r = route[k] else { continue }
                var seen = Set<Int>()
                activeGrids[k].forEach(in: r.box.insetBy(-clearance)) { m in
                    guard !exhausted, m != excluded.0, m != excluded.1, seen.insert(m).inserted else { return }
                    let value = risk(r, active[m][k])
                    if value.passes > 0 { rows[m] = (rows[m] ?? AssignmentRisk()) + value }
                }
            }
        }
        let anchors = assignmentAnchors(members, at: setID)
        func travel(_ member: Int, _ dot: Int) -> Double { Self.squaredTravel(anchors[member], to: targets[dot]) }
        func strides(_ route: [AssignmentRoute?]) -> Int { route.reduce(0) { $0 + (($1?.overstride ?? false) ? 1 : 0) } }

        // Sparse pair risks: only pairs that actually conflict are stored.
        var neighbors = [[Int: AssignmentRisk]](repeating: [:], count: n)
        var totals = (0..<n).map { fixedRisk(order[$0], $0) }
        guard !exhausted else { return members }
        for i in 0..<n {
            var rows: [Int: AssignmentRisk] = [:]
            activeRisk(active[i], excluding: (i, i), into: &rows)
            if exhausted { return members }
            for (j, value) in rows where j > i {
                neighbors[i][j] = value; neighbors[j][i] = value
                totals[i] = totals[i] + value; totals[j] = totals[j] + value
            }
        }

        for _ in 0..<8 {
            var changed = false
            for i in 0..<n {
                if exhausted { return order.map { members[$0] } }
                guard totals[i].passes > 0 else { continue }
                // Nearby dots plus every conflicting partner, cheapest first.
                var candidates: [(index: Int, cost: Double)] = Set(nearest(i)).union(neighbors[i].keys).map { j in
                    let swapped = travel(order[j], i) + travel(order[i], j)
                    return (j, swapped - travel(order[i], i) - travel(order[j], j))
                }
                candidates.sort { $0.cost == $1.cost ? $0.index < $1.index : $0.cost < $1.cost }
                var best: Int?, bestDelta = SwapDelta()
                for candidate in candidates {
                    let j = candidate.index
                    let left = routes(order[j], i), right = routes(order[i], j)
                    let before = totals[i] + totals[j] - (neighbors[i][j] ?? AssignmentRisk())
                    var after = fixedRisk(order[j], i) + fixedRisk(order[i], j)
                    if exhausted { break }
                    for k in moves.indices { after = after + risk(left[k], right[k]) }
                    var rows: [Int: AssignmentRisk] = [:]
                    activeRisk(left, excluding: (i, j), into: &rows)
                    activeRisk(right, excluding: (i, j), into: &rows)
                    if exhausted { break }
                    after = rows.values.reduce(after, +)
                    let risk = after - before
                    let delta = SwapDelta(warnings: risk.passes + strides(left) + strides(right) - strides(active[i]) - strides(active[j]),
                                          deficit: risk.deficit, travel: candidate.cost)
                    if delta.improves(on: bestDelta) {
                        best = j; bestDelta = delta
                        if after.passes == 0 && risk.passes < 0 { break }
                    }
                }
                guard let j = best else { continue }
                // The accepted swap was fully scored above.
                for row in [i, j] {
                    for (k, value) in neighbors[row] where k != i && k != j {
                        neighbors[k][row] = nil
                        totals[k] = totals[k] - value
                    }
                    for k in moves.indices { if let box = active[row][k]?.box { activeGrids[k].remove(row, box) } }
                }
                order.swapAt(i, j)
                for row in [i, j] {
                    active[row] = routes(order[row], row)
                    for k in moves.indices { if let box = active[row][k]?.box { activeGrids[k].insert(row, box) } }
                }
                // Refresh just the changed rows; untouched pairs remain valid.
                var mutual = AssignmentRisk()
                for k in moves.indices { mutual = mutual + risk(active[i][k], active[j][k]) }
                var rows = [[Int: AssignmentRisk]](repeating: [:], count: 2)
                for (slot, row) in [i, j].enumerated() {
                    activeRisk(active[row], excluding: (i, j), into: &rows[slot])
                }
                if exhausted { return order.map { members[$0] } }
                for (slot, row) in [i, j].enumerated() {
                    neighbors[row] = rows[slot]
                    if mutual.passes > 0 { neighbors[row][slot == 0 ? j : i] = mutual }
                    totals[row] = neighbors[row].values.reduce(fixedRisk(order[row], row), +)
                    for (k, value) in rows[slot] {
                        neighbors[k][row] = value
                        totals[k] = totals[k] + value
                    }
                }
                changed = true
            }
            if !changed { break }
        }
        return order.map { members[$0] }
    }
}
