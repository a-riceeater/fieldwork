import Foundation

extension Show {
    /// Returns members in target-dot order, starting with minimum straight-line travel
    /// in meters. Sections and labels never contribute to the distance cost.
    /// Unplaced members fill unused dots in stable roster order after placed
    /// members have been matched. An unresolved arrival uses its previous set.
    func proximityOrder(_ ids: [PerformerID], to targets: [Point2], at setID: SetID) -> [PerformerID] {
        let members = sequentialOrder(Array(Set(ids)))
        precondition(members.count == targets.count)
        let current = formation(setID)
        let previous = previousSet(before: setID).map { formation($0.id) }
        let located = members.compactMap { id -> (id: PerformerID, point: Point2)? in
            let position = current[id].position ?? (current[id] == .unresolved ? previous?[id].position : nil)
            return position.map { (id, $0.point) }
        }
        guard !located.isEmpty else { return collisionAwareOrder(members, to: targets, at: setID) }
        let costs = located.map { member in targets.map { member.point.distance(to: $0) } }
        // Invalid geometry must reach normal command validation, never stall
        // the augmenting-path search on an infinite or NaN cost.
        guard costs.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { return members }
        let matching = Self.minimumDistanceAssignment(costs)
        var ordered = [PerformerID?](repeating: nil, count: targets.count)
        for (row, column) in matching.enumerated() { ordered[column] = located[row].id }
        let placedIDs = Set(located.map(\.id))
        var remaining = members.filter { !placedIDs.contains($0) }.makeIterator()
        let result = ordered.map { $0 ?? remaining.next()! }
        return collisionAwareOrder(result, to: targets, at: setID)
    }

    /// Rectangular Hungarian assignment: one distinct column per row, with
    /// rows <= columns. Strict comparisons and stable traversal break ties
    /// reproducibly, independent of selection-set iteration order.
    private static func minimumDistanceAssignment(_ costs: [[Double]]) -> [Int] {
        let rows = costs.count, columns = costs[0].count
        var rowPotential = [Double](repeating: 0, count: rows + 1)
        var columnPotential = [Double](repeating: 0, count: columns + 1)
        var owner = [Int](repeating: 0, count: columns + 1)
        var predecessor = [Int](repeating: 0, count: columns + 1)
        for row in 1...rows {
            owner[0] = row
            var column = 0
            var slack = [Double](repeating: .infinity, count: columns + 1)
            var visited = [Bool](repeating: false, count: columns + 1)
            repeat {
                visited[column] = true
                let activeRow = owner[column]
                var delta = Double.infinity, next = 0
                for candidate in 1...columns where !visited[candidate] {
                    let cost = costs[activeRow - 1][candidate - 1]
                        - rowPotential[activeRow] - columnPotential[candidate]
                    if cost < slack[candidate] {
                        slack[candidate] = cost
                        predecessor[candidate] = column
                    }
                    if slack[candidate] < delta {
                        delta = slack[candidate]
                        next = candidate
                    }
                }
                for candidate in 0...columns {
                    if visited[candidate] {
                        rowPotential[owner[candidate]] += delta
                        columnPotential[candidate] -= delta
                    } else {
                        slack[candidate] -= delta
                    }
                }
                column = next
            } while owner[column] != 0
            repeat {
                let previous = predecessor[column]
                owner[column] = owner[previous]
                column = previous
            } while column != 0
        }
        var result = [Int](repeating: 0, count: rows)
        for column in 1...columns where owner[column] != 0 {
            result[owner[column] - 1] = column - 1
        }
        return result
    }
}
