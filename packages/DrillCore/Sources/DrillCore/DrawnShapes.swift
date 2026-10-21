import Foundation

/// A shape drawn on the field before anyone is chosen to stand in it, as in
/// Draw Next Set. Performers are spread over all drawn shapes at one common
/// spacing when the set is routed.
public enum DrawnShape: Hashable, Codable, Sendable {
    case curve(points: [Point2])
    case line(start: Point2, end: Point2)
    /// `bulge` is the signed sagitta in meters, as in `FormGeometry.arc`.
    case arc(start: Point2, end: Point2, bulge: Double)
    /// A filled block between two opposite corners, rows front to back.
    case block(Point2, Point2)
    case circle(center: Point2, radius: Double)
    case text(TextShape)

    public var kindName: String {
        switch self {
        case .curve: return "Curve"
        case .line: return "Line"
        case .arc: return "Arc"
        case .block: return "Block"
        case .circle: return "Circle"
        case .text: return "Text"
        }
    }

    /// Lines, arcs, curves and circles become retained forms with handles once routed.
    public var formGeometry: FormGeometry? {
        switch self {
        case .curve(let points): return .curve(points: points)
        case .line(let s, let e): return .line(start: s, end: e)
        case .arc(let s, let e, let b): return .arc(start: s, end: e, bulge: b)
        case .circle(let c, let r): return .circle(center: c, radius: r)
        default: return nil
        }
    }

    private var rect: Rect2? {
        guard case .block(let a, let b) = self else { return nil }
        return Rect2(points: [a, b])
    }

    /// Outlines for drawing, in world meters.
    public var outlines: [[Point2]] {
        switch self {
        case .line, .arc, .curve: return [formGeometry!.polyline()]
        case .block:
            let r = rect!
            return [[Point2(r.minX, r.minY), Point2(r.maxX, r.minY), Point2(r.maxX, r.maxY), Point2(r.minX, r.maxY), Point2(r.minX, r.minY)]]
        case .circle(let c, let radius):
            return [(0...64).map { i in
                let angle = 2 * Double.pi * Double(i) / 64
                return c + Point2(radius * cos(angle), radius * sin(angle))
            }]
        case .text(let text): return (try? text.strokes()) ?? []
        }
    }

    public func validate() throws {
        let numbers: [Double]
        switch self {
        case .curve(let points):
            numbers = points.flatMap { [$0.x, $0.y] }
            guard points.count >= 2, formGeometry!.length > 1e-6 else { throw DrillError("Place at least two distinct curve points.") }
        case .line(let s, let e), .arc(let s, let e, _):
            if case .arc(_, _, let b) = self { numbers = [s.x, s.y, e.x, e.y, b] } else { numbers = [s.x, s.y, e.x, e.y] }
            guard s.distance(to: e) > 1e-6 else { throw DrillError("Drag to give the \(kindName.lowercased()) a length.") }
        case .block(let a, let b):
            numbers = [a.x, a.y, b.x, b.y]
            guard max(abs(a.x - b.x), abs(a.y - b.y)) > 1e-6 else { throw DrillError("Drag to give the block a size.") }
        case .circle(let c, let r):
            numbers = [c.x, c.y, r]
            guard r > 1e-6 else { throw DrillError("Drag to give the circle a size.") }
        case .text(let text):
            numbers = [text.start.x, text.start.y, text.end.x, text.end.y]
            _ = try TextShape.validated(text.text)
        }
        guard numbers.allSatisfy(\.isFinite) else { throw DrillError("Shapes must have finite coordinates.") }
    }

    /// Fewest dots that still show the shape.
    func minimumCount() throws -> Int {
        switch self {
        case .line, .arc, .curve: return 2
        case .block: return 1
        case .circle: return 3
        case .text(let text): return try text.minimumCount()
        }
    }

    /// Dots the shape holds at about `spacing` apart.
    func capacity(spacing s: Double) throws -> Int {
        switch self {
        case .line, .arc, .curve: return max(2, Int((formGeometry!.length / s).rounded()) + 1)
        case .block:
            let r = rect!
            return (Int((r.width / s).rounded()) + 1) * (Int((r.height / s).rounded()) + 1)
        case .circle(_, let radius): return max(3, Int((2 * .pi * radius / s).rounded()))
        case .text(let text): return try text.capacity(spacing: s)
        }
    }

    /// Distance between neighbors when the shape holds `count` dots; the shape
    /// with the widest spacing receives any dots left over.
    func spacing(_ count: Int) -> Double {
        switch self {
        case .line, .arc, .curve: return formGeometry!.length / Double(max(1, count - 1))
        case .block:
            let r = rect!
            return r.width * r.height > 1e-9 ? (r.width * r.height / Double(count)).squareRoot() : max(r.width, r.height) / Double(max(1, count - 1))
        case .circle(_, let radius): return 2 * .pi * radius / Double(count)
        case .text(let text):
            let length = ((try? text.strokes()) ?? []).reduce(0) { total, stroke in
                total + zip(stroke, stroke.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            }
            return length / Double(count)
        }
    }

    /// Exactly `count` dots on the shape.
    public func points(_ count: Int) throws -> [Point2] {
        guard count > 0 else { return [] }
        switch self {
        case .line, .arc, .curve: return formGeometry!.distribute(count)
        case .block: return Self.gridPoints(count, in: rect!)
        case .circle(let c, let radius):
            // The first dot faces the audience, like the Circle quick shape.
            return (0..<count).map { i in
                let angle = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(count)
                return c + Point2(radius * cos(angle), radius * sin(angle))
            }
        case .text(let text): return try text.points(count)
        }
    }

    /// Rows front to back filling the rectangle at an equal spacing both ways
    /// where possible; the back row is centered when it is not full.
    static func gridPoints(_ count: Int, in rect: Rect2) -> [Point2] {
        guard count > 1 else { return [rect.center] }
        let w = rect.width, h = rect.height
        // Spacing s solving (w/s + 1)(h/s + 1) = count.
        let k = Double(count - 1)
        let s = ((w + h) + ((w + h) * (w + h) + 4 * k * w * h).squareRoot()) / (2 * k)
        let columns = s > 1e-9 ? min(count, max(1, Int((w / s).rounded()) + 1)) : 1
        let rows = (count + columns - 1) / columns
        let dx = columns > 1 ? w / Double(columns - 1) : 0
        let dy = rows > 1 ? h / Double(rows - 1) : 0
        return (0..<count).map { i in
            let row = i / columns, column = i % columns
            let inRow = min(columns, count - row * columns)
            let x = rect.center.x + (Double(column) - Double(inRow - 1) / 2) * dx
            return Point2(x, rows > 1 ? rect.minY + Double(row) * dy : rect.center.y)
        }
    }
}

extension Show {
    /// Recovers an evenly spaced circle saved as plain dots by older versions.
    /// Only accept the original circle layout, so adopting it leaves positions intact.
    public func recoverCircle(members ids: [PerformerID], at setID: SetID) -> Form? {
        let ids = Array(Set(ids))
        guard ids.count >= 3 else { return nil }
        let formation = formation(setID)
        let points = ids.compactMap { formation[$0].position?.point }
        guard points.count == ids.count else { return nil }
        let center = points.reduce(.zero, +) / Double(points.count)
        let radius = points.reduce(0) { $0 + $1.distance(to: center) } / Double(points.count)
        guard radius.isFinite, radius > 1e-6 else { return nil }
        func angle(_ id: PerformerID) -> Double {
            let p = formation[id].position!.point - center
            let angle = atan2(p.y, p.x) + .pi / 2
            return angle < -1e-8 ? angle + 2 * .pi : angle
        }
        let members = ids.sorted { angle($0) < angle($1) }
        let geometry = FormGeometry.circle(center: center, radius: radius)
        let targets = geometry.distribute(members.count)
        guard zip(members, targets).allSatisfy({ id, target in
            formation[id].position!.point.distance(to: target) < 1e-5
        }) else { return nil }
        return Form(setID: setID, geometry: geometry, members: members)
    }

    /// Spreads `count` dots over the shapes at one common spacing: the widest
    /// spacing that needs no more than `count`, with any remainder going to the
    /// shapes whose dots are farthest apart. Returns each shape's dots in order.
    public func drawnTargets(_ shapes: [DrawnShape], count: Int) throws -> [[Point2]] {
        guard !shapes.isEmpty else { throw DrillError("Draw at least one shape first.") }
        guard count > 0 else { throw DrillError("Choose who fills the shapes.") }
        for shape in shapes { try shape.validate() }
        let minimums = try shapes.map { try $0.minimumCount() }
        let needed = minimums.reduce(0, +)
        guard count >= needed else {
            throw DrillError("These shapes need at least \(needed) performers. Choose more performers or remove a shape.")
        }
        func counts(_ s: Double) throws -> [Int] {
            try zip(shapes, minimums).map { max($1, try $0.capacity(spacing: s)) }
        }
        // Total dots shrink as spacing grows; find the widest spacing that fits.
        let extent = shapes.flatMap { $0.outlines.flatMap { $0 } }
        let span = extent.isEmpty ? 1 : max(Rect2(points: extent).width, Rect2(points: extent).height, 1)
        var low = span / Double(count * 8 + 8), high = span * 4 + 1
        var best = try counts(high)
        if try counts(low).reduce(0, +) <= count {
            best = try counts(low)
        } else {
            for _ in 0..<48 {
                let mid = (low + high) / 2
                let candidate = try counts(mid)
                if candidate.reduce(0, +) > count { low = mid } else { high = mid; best = candidate }
            }
        }
        var remaining = count - best.reduce(0, +)
        while remaining > 0 {
            let i = shapes.indices.max { a, b in
                let sa = shapes[a].spacing(best[a]), sb = shapes[b].spacing(best[b])
                return sa != sb ? sa < sb : a > b
            }!
            best[i] += 1
            remaining -= 1
        }
        return try zip(shapes, best).map { try $0.points($1) }
    }

    /// Fills drawn shapes with `ids` as one undoable step, matching performers to
    /// dots with the same proximity and collision assignment the quick shapes use.
    /// Lines, arcs, curves and circles become forms with handles; blocks and text are plain
    /// positions. With `holdOthers`, everyone else stands where they were at the
    /// previous set, so leaving a section out of the route keeps it in place.
    public func makeDrawnSet(_ shapes: [DrawnShape], members ids: [PerformerID], at setID: SetID,
                             holdOthers: Bool = false, name: String? = nil) throws -> DrillCommand {
        guard let set = set(setID) else { throw DrillError("Unknown set.") }
        let known = Set(performers.map(\.id))
        let members = sequentialOrder(Array(Set(ids).intersection(known)))
        guard !members.isEmpty else { throw DrillError("Choose who fills the shapes.") }
        let targets = try drawnTargets(shapes, count: members.count)

        var holds: [PerformerID: Placement] = [:]
        if holdOthers, let previous = previousSet(before: setID) {
            let chosen = Set(members), before = formation(previous.id), current = formation(setID)
            for performer in performers where !chosen.contains(performer.id) && current[performer.id] != before[performer.id] {
                holds[performer.id] = before[performer.id]
            }
        }
        // Collision checks see the held performers where they will stand.
        let base = holds.isEmpty ? self : try DrillCommand.setPlacements(setID, holds).applied(to: self)
        let ordered = base.proximityOrder(members, to: targets.flatMap { $0 }, at: setID)

        var plain = holds
        var forms: [DrillCommand] = []
        var offset = 0
        for (shape, points) in zip(shapes, targets) {
            let chunk = Array(ordered[offset..<offset + points.count])
            offset += points.count
            if let geometry = shape.formGeometry, geometry.length > 1e-6 {
                forms.append(.applyForm(Form(setID: setID, geometry: geometry, members: chunk)))
                continue
            }
            for (id, p) in zip(chunk, points) {
                var position = base.formation(setID)[id].position ?? Position(x: p.x, y: p.y)
                position.point = p
                plain[id] = .placed(position)
            }
        }
        let commands: [DrillCommand] = (plain.isEmpty ? [] : [.setPlacements(setID, plain)]) + forms
        return .batch(name ?? "Draw Set \(set.label)", commands)
    }

    /// Spells `text` with the selection, centered on where they stand (or on the
    /// field center), sized so neighbors sit about `spacingSteps` apart.
    public func makeQuickText(_ text: String, members ids: [PerformerID], at setID: SetID,
                              spacingSteps: Double = 2, center: Point2? = nil) throws -> DrillCommand {
        guard set(setID) != nil else { throw DrillError("Unknown set.") }
        let members = Array(Set(ids).intersection(performers.map(\.id)))
        guard !members.isEmpty else { throw DrillError("Select performers first, then choose a shape.") }
        guard spacingSteps.isFinite, spacingSteps > 0 else { throw DrillError("Spacing must be more than zero steps.") }
        let text = try TextShape.validated(text)
        let placed = members.compactMap { formation(setID)[$0].position?.point }
        let c = center ?? (placed.isEmpty ? .zero : Rect2(points: placed).center)

        // Size the unit-height layout so its strokes hold the selection at the spacing.
        let layout = try StrokeFont.layout(text)
        let strokeLength = layout.strokes.reduce(0) { total, stroke in
            total + zip(stroke, stroke.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        }
        var scale = strokeLength > 0 ? Double(members.count) * spacingSteps * field.stepSize / strokeLength : 1
        // Keep the letters on the field.
        scale = min(scale, field.length * 0.9 / max(layout.width, 1e-9), field.width * 0.8 / StrokeFont.capHeight)
        let width = layout.width * scale, height = StrokeFont.capHeight * scale
        let shape = TextShape(text, start: Point2(c.x - width / 2, c.y - height / 2), end: Point2(c.x + width / 2, c.y - height / 2))
        return try makeDrawnSet([.text(shape)], members: members, at: setID, name: "Spell \(text)")
    }
}
