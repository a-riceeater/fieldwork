import Foundation

extension Show {
    /// Returns members in target-dot order, starting with minimum total squared
    /// marching distance: from each member's previous-set position and to their
    /// next-set position. Squaring keeps everyone's move short rather than sending
    /// one performer across the form to save others a little. When only the move
    /// from the previous set is matched and everyone travels straight, no two
    /// matched performers come closer than 1/√2 of their spacing at the start or
    /// the end (swapping their dots would otherwise cost less). Members with
    /// neither neighbor placed match from their current position. Sections and
    /// labels never contribute to the cost. Members with no position at all fill
    /// unused dots in stable roster order after the others have been matched.
    func proximityOrder(_ ids: [PerformerID], to targets: [Point2], at setID: SetID) -> [PerformerID] {
        let members = sequentialOrder(Array(Set(ids)))
        precondition(members.count == targets.count)
        let anchors = assignmentAnchors(members, at: setID)
        let located = members.indices.filter { !anchors[$0].isEmpty }
        guard !located.isEmpty else { return collisionAwareOrder(members, to: targets, at: setID) }
        var costs: [Double] = []
        costs.reserveCapacity(located.count * targets.count)
        for member in located {
            for target in targets { costs.append(Self.squaredTravel(anchors[member], to: target)) }
        }
        // Invalid geometry must reach normal command validation, never stall
        // the augmenting-path search on an infinite or NaN cost.
        guard costs.allSatisfy(\.isFinite) else { return members }
        let matching = Self.minimumCostAssignment(costs, rows: located.count, columns: targets.count)
        var ordered = [PerformerID?](repeating: nil, count: targets.count)
        for (row, column) in matching.enumerated() { ordered[column] = members[located[row]] }
        let placedIDs = Set(located.map { members[$0] })
        var remaining = members.filter { !placedIDs.contains($0) }.makeIterator()
        let result = ordered.map { $0 ?? remaining.next()! }
        return collisionAwareOrder(result, to: targets, at: setID)
    }

    /// The points each member marches from and to around this set: their
    /// previous- and next-set positions, else their current position. Empty for
    /// members with none of these, and for members inactive on this set.
    func assignmentAnchors(_ members: [PerformerID], at setID: SetID) -> [[Point2]] {
        let current = formation(setID)
        let neighbors = [previousSet(before: setID), nextSet(after: setID)].compactMap { $0.map { formation($0.id) } }
        return members.map { id in
            guard current[id] != .inactive else { return [] }
            let points = neighbors.compactMap { $0[id].position?.point }
            return points.isEmpty ? current[id].position.map { [$0.point] } ?? [] : points
        }
    }

    static func squaredTravel(_ anchors: [Point2], to dot: Point2) -> Double {
        anchors.reduce(0) { total, anchor in
            let d = anchor - dot
            return total + d.dot(d)
        }
    }

    /// Rectangular minimum-cost assignment over row-major `costs`: one distinct
    /// column per row, with rows <= columns. Shortest augmenting paths with
    /// lazy dual updates (Jonker–Volgenant style); each step scans only the
    /// columns not yet reached and prefers a free column on ties. The scan order
    /// is fixed, so ties break reproducibly, independent of selection-set order.
    private static func minimumCostAssignment(_ costs: [Double], rows: Int, columns: Int) -> [Int] {
        // Raw buffers keep the cubic inner loop free of array checks, which
        // otherwise dominate unoptimized (Debug) builds.
        func buffer<T>(_ value: T, _ count: Int) -> UnsafeMutableBufferPointer<T> {
            let pointer = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
            pointer.initialize(repeating: value)
            return pointer
        }
        let u = buffer(0.0, rows), v = buffer(0.0, columns)
        let shortest = buffer(Double.infinity, columns), path = buffer(-1, columns)
        let rowForColumn = buffer(-1, columns), columnForRow = buffer(-1, rows)
        let remaining = buffer(0, columns)
        let rowVisited = buffer(false, rows), columnVisited = buffer(false, columns)
        defer {
            for pointer in [u, v, shortest] { pointer.deallocate() }
            for pointer in [path, rowForColumn, columnForRow, remaining] { pointer.deallocate() }
            for pointer in [rowVisited, columnVisited] { pointer.deallocate() }
        }
        costs.withUnsafeBufferPointer { costs in
            for start in 0..<rows {
                shortest.update(repeating: .infinity)
                rowVisited.update(repeating: false)
                columnVisited.update(repeating: false)
                for j in 0..<columns { remaining[j] = columns - 1 - j }
                var open = columns, minimum = 0.0, row = start, sink = -1
                while sink < 0 {
                    rowVisited[row] = true
                    let base = row * columns, potential = u[row]
                    var lowest = Double.infinity, pick = -1
                    for k in 0..<open {
                        let j = remaining[k]
                        let reduced = minimum + costs[base + j] - potential - v[j]
                        if reduced < shortest[j] {
                            path[j] = row
                            shortest[j] = reduced
                        }
                        if shortest[j] < lowest || (shortest[j] == lowest && rowForColumn[j] < 0) {
                            lowest = shortest[j]
                            pick = k
                        }
                    }
                    minimum = lowest
                    let j = remaining[pick]
                    if rowForColumn[j] < 0 { sink = j } else { row = rowForColumn[j] }
                    columnVisited[j] = true
                    open -= 1
                    remaining[pick] = remaining[open]
                }
                u[start] += minimum
                for i in 0..<rows where rowVisited[i] && i != start {
                    u[i] += minimum - shortest[columnForRow[i]]
                }
                for j in 0..<columns where columnVisited[j] {
                    v[j] -= minimum - shortest[j]
                }
                var j = sink
                while true {
                    let i = path[j]
                    rowForColumn[j] = i
                    swap(&columnForRow[i], &j)
                    if i == start { break }
                }
            }
        }
        return Array(columnForRow)
    }
}
