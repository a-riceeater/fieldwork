import Foundation

/// Ready-made shapes for getting performers onto the field in one step.
public enum QuickShape: String, CaseIterable, Sendable {
    case line, arc, block, circle

    public var displayName: String {
        switch self {
        case .line: return "Line"
        case .arc: return "Arc"
        case .block: return "Block"
        case .circle: return "Circle"
        }
    }
}

extension Show {
    /// Places performers, in drill-label order, into a shape on one set as a
    /// single undoable step. Lines and arcs become retained forms with handles;
    /// blocks and circles are plain positions. The shape is centered on the
    /// performers' current positions, or on the field center when none are placed.
    public func makeQuickShape(_ shape: QuickShape, members ids: [PerformerID], at setID: SetID,
                               spacingSteps: Double = 2, center: Point2? = nil) throws -> DrillCommand {
        guard set(setID) != nil else { throw DrillError("Unknown set.") }
        let members = sequentialOrder(ids.filter { performer($0) != nil })
        guard !members.isEmpty else { throw DrillError("Select performers first, then choose a shape.") }
        guard spacingSteps.isFinite, spacingSteps > 0 else { throw DrillError("Spacing must be more than zero steps.") }
        let spacing = spacingSteps * field.stepSize
        let placed = members.compactMap { formation(setID)[$0].position?.point }
        let c = center ?? (placed.isEmpty ? .zero : Rect2(points: placed).center)
        let n = members.count
        let name = "Place in \(shape.displayName)"

        switch shape {
        case .line, .arc where n == 1:
            let half = Double(n - 1) * spacing / 2
            return .batch(name, [try makeForm(.line(start: c - Point2(half, 0), end: c + Point2(half, 0)), members: members, at: setID)])
        case .arc:
            // A sagitta of a quarter chord makes the arc 1.159 times the chord;
            // size the chord so neighbors sit about `spacing` apart along the arc.
            let chord = Double(n - 1) * spacing / 1.1591
            let bulge = -0.25 * chord // bows toward the audience
            let y = c.y - bulge / 2
            let geometry = FormGeometry.arc(start: Point2(c.x - chord / 2, y), end: Point2(c.x + chord / 2, y), bulge: bulge)
            return .batch(name, [try makeForm(geometry, members: members, at: setID)])
        case .block:
            return .batch(name, [.setPlacements(setID, placements(members, at: Self.blockPoints(n, spacing: spacing, center: c), in: setID))])
        case .circle:
            let radius = max(spacing, Double(n) * spacing / (2 * .pi))
            let points = (0..<n).map { i -> Point2 in
                let angle = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
                return c + Point2(radius * cos(angle), radius * sin(angle))
            }
            return .batch(name, [.setPlacements(setID, placements(members, at: points, in: setID))])
        }
    }

    /// Puts every performer without a position on this set onto the field:
    /// one block per section, side by side, wrapping to new rows when the field runs out.
    public func makePlaceUnplaced(at setID: SetID, spacingSteps: Double = 2) throws -> DrillCommand {
        guard set(setID) != nil else { throw DrillError("Unknown set.") }
        let formation = formation(setID)
        let spacing = spacingSteps * field.stepSize
        let groups = sections.map { section in performers(in: section.id).map(\.id).filter { formation[$0] == .unresolved } }.filter { !$0.isEmpty }
        guard !groups.isEmpty else { throw DrillError("Everyone already has a position on this set.") }

        // Lay blocks out in rows that fit the field, then center the whole arrangement.
        struct Block { var members: [PerformerID]; var columns: Int; var rows: Int; var origin = Point2.zero }
        var blocks = groups.map { members -> Block in
            let columns = Self.blockColumns(members.count)
            return Block(members: members, columns: columns, rows: (members.count + columns - 1) / columns)
        }
        let gap = 2 * spacing
        let maxWidth = field.length * 0.9
        var x = 0.0, y = 0.0, rowDepth = 0.0, rowStart = 0
        var rows: [(range: Range<Int>, width: Double)] = []
        for i in blocks.indices {
            let width = Double(blocks[i].columns - 1) * spacing
            if x > 0, x + width > maxWidth {
                rows.append((rowStart..<i, x - gap))
                y -= rowDepth + gap
                x = 0; rowDepth = 0; rowStart = i
            }
            blocks[i].origin = Point2(x, y)
            x += width + gap
            rowDepth = max(rowDepth, Double(blocks[i].rows - 1) * spacing)
        }
        rows.append((rowStart..<blocks.count, x - gap))
        let totalDepth = -y + rowDepth
        var placements: [PerformerID: Placement] = [:]
        for row in rows {
            for i in row.range {
                let b = blocks[i]
                let blockCenter = Point2(b.origin.x - row.width / 2 + Double(b.columns - 1) * spacing / 2,
                                         b.origin.y + totalDepth / 2 - Double(b.rows - 1) * spacing / 2)
                let points = Self.blockPoints(b.members.count, spacing: spacing, center: blockCenter, columns: b.columns)
                for (id, p) in zip(b.members, points) { placements[id] = .placed(Position(x: p.x, y: p.y)) }
            }
        }
        return .batch(placements.count == 1 ? "Place Performer" : "Place \(placements.count) Performers", [.setPlacements(setID, placements)])
    }

    private func placements(_ members: [PerformerID], at points: [Point2], in setID: SetID) -> [PerformerID: Placement] {
        var result: [PerformerID: Placement] = [:]
        for (id, p) in zip(members, points) {
            var position = formation(setID)[id].position ?? Position(x: p.x, y: p.y)
            position.x = p.x
            position.y = p.y
            result[id] = .placed(position)
        }
        return result
    }

    /// Roughly twice as wide as deep, at most 8 across.
    static func blockColumns(_ count: Int) -> Int {
        count <= 4 ? max(count, 1) : min(8, Int(ceil(sqrt(Double(count) * 2))))
    }

    /// Rows from front to back, each row centered side to side.
    static func blockPoints(_ count: Int, spacing: Double, center: Point2, columns: Int? = nil) -> [Point2] {
        let columns = columns ?? blockColumns(count)
        let rows = (count + columns - 1) / columns
        return (0..<count).map { i in
            let row = i / columns, column = i % columns
            let inRow = min(columns, count - row * columns)
            return Point2(center.x + (Double(column) - Double(inRow - 1) / 2) * spacing,
                          center.y + (Double(row) - Double(rows - 1) / 2) * spacing)
        }
    }
}
