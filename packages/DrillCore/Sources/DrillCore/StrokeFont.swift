import Foundation

/// Single-stroke capitals, digits and a little punctuation for spelling with
/// performers. Each glyph is drawn on a grid 6 units tall with its baseline at
/// y = 0; curves are cut corners, which read clearly as dots. A stroke whose
/// first and last points match is closed. A one-point stroke is a single dot.
enum StrokeFont {
    static let capHeight = 6.0
    /// Space between neighboring glyphs, and the width of a word space, in grid units.
    static let letterGap = 1.5
    static let wordSpace = 3.0

    typealias Glyph = [[Point2]]

    private static func g(_ strokes: [(Double, Double)]...) -> Glyph {
        strokes.map { $0.map { Point2($0.0, $0.1) } }
    }

    private static let ring: [(Double, Double)] = [(1, 0), (0, 1), (0, 5), (1, 6), (3, 6), (4, 5), (4, 1), (3, 0), (1, 0)]
    private static let bowl: [(Double, Double)] = [(0, 0), (0, 6), (3, 6), (4, 5), (4, 4), (3, 3), (0, 3)]

    static let glyphs: [Character: Glyph] = [
        "A": g([(0, 0), (2, 6), (4, 0)], [(1, 3), (3, 3)]),
        "B": g([(0, 0), (0, 6), (3, 6), (4, 5), (4, 4), (3, 3), (0, 3)], [(3, 3), (4, 2), (4, 1), (3, 0), (0, 0)]),
        "C": g([(4, 5), (3, 6), (1, 6), (0, 5), (0, 1), (1, 0), (3, 0), (4, 1)]),
        "D": g([(0, 0), (0, 6), (2, 6), (4, 4), (4, 2), (2, 0), (0, 0)]),
        "E": g([(4, 6), (0, 6), (0, 0), (4, 0)], [(0, 3), (3, 3)]),
        "F": g([(4, 6), (0, 6), (0, 0)], [(0, 3), (3, 3)]),
        "G": g([(4, 5), (3, 6), (1, 6), (0, 5), (0, 1), (1, 0), (3, 0), (4, 1), (4, 3), (2, 3)]),
        "H": g([(0, 0), (0, 6)], [(4, 0), (4, 6)], [(0, 3), (4, 3)]),
        "I": g([(0, 6), (2, 6)], [(1, 6), (1, 0)], [(0, 0), (2, 0)]),
        "J": g([(4, 6), (4, 1), (3, 0), (1, 0), (0, 1)]),
        "K": g([(0, 0), (0, 6)], [(4, 6), (0, 2)], [(1, 3), (4, 0)]),
        "L": g([(0, 6), (0, 0), (4, 0)]),
        "M": g([(0, 0), (0, 6), (2, 3), (4, 6), (4, 0)]),
        "N": g([(0, 0), (0, 6), (4, 0), (4, 6)]),
        "O": g(ring),
        "P": g(bowl),
        "Q": g(ring, [(2, 2), (4, 0)]),
        "R": g(bowl, [(2, 3), (4, 0)]),
        "S": g([(4, 5), (3, 6), (1, 6), (0, 5), (0, 4), (1, 3), (3, 3), (4, 2), (4, 1), (3, 0), (1, 0), (0, 1)]),
        "T": g([(0, 6), (4, 6)], [(2, 6), (2, 0)]),
        "U": g([(0, 6), (0, 1), (1, 0), (3, 0), (4, 1), (4, 6)]),
        "V": g([(0, 6), (2, 0), (4, 6)]),
        "W": g([(0, 6), (1, 0), (2, 4), (3, 0), (4, 6)]),
        "X": g([(0, 0), (4, 6)], [(0, 6), (4, 0)]),
        "Y": g([(0, 6), (2, 3), (4, 6)], [(2, 3), (2, 0)]),
        "Z": g([(0, 6), (4, 6), (0, 0), (4, 0)]),
        "0": g(ring),
        "1": g([(0, 5), (1, 6), (1, 0)], [(0, 0), (2, 0)]),
        "2": g([(0, 5), (1, 6), (3, 6), (4, 5), (4, 4), (0, 0), (4, 0)]),
        "3": g([(0, 5), (1, 6), (3, 6), (4, 5), (4, 4), (3, 3), (4, 2), (4, 1), (3, 0), (1, 0), (0, 1)], [(1, 3), (3, 3)]),
        "4": g([(3, 0), (3, 6), (0, 2), (4, 2)]),
        "5": g([(4, 6), (0, 6), (0, 3), (3, 3), (4, 2), (4, 1), (3, 0), (1, 0), (0, 1)]),
        "6": g([(3, 6), (1, 6), (0, 5), (0, 1), (1, 0), (3, 0), (4, 1), (4, 2), (3, 3), (0, 3)]),
        "7": g([(0, 6), (4, 6), (1, 0)]),
        "8": g([(1, 3), (0, 4), (0, 5), (1, 6), (3, 6), (4, 5), (4, 4), (3, 3), (1, 3), (0, 2), (0, 1), (1, 0), (3, 0), (4, 1), (4, 2), (3, 3)]),
        "9": g([(4, 3), (1, 3), (0, 4), (0, 5), (1, 6), (3, 6), (4, 5), (4, 1), (3, 0), (1, 0)]),
        "!": g([(0, 6), (0, 2)], [(0, 0)]),
        "?": g([(0, 5), (1, 6), (3, 6), (4, 5), (4, 4), (2, 2.5), (2, 1.5)], [(2, 0)]),
        ".": g([(0, 0)]),
        ",": g([(0.5, 0), (0, -1)]),
        "'": g([(0, 6), (0, 4.5)]),
        "-": g([(0, 3), (3, 3)]),
        "+": g([(2, 1), (2, 5)], [(0, 3), (4, 3)]),
        "/": g([(0, 0), (4, 6)]),
        "&": g([(4, 0), (1, 5), (2, 6), (3, 5), (0, 2), (0, 1), (1, 0), (2, 0), (4, 2)]),
        "#": g([(1, 0), (1.5, 6)], [(2.5, 0), (3, 6)], [(0, 2), (4, 2)], [(0, 4), (4, 4)]),
    ]

    /// Strokes of `text` in grid units, left to right from x = 0, plus the
    /// overall advance width. Letters are matched case-insensitively.
    static func layout(_ text: String) throws -> (strokes: [[Point2]], width: Double) {
        var strokes: [[Point2]] = []
        var x = 0.0
        var pendingGap = false
        for character in text.uppercased() {
            if character == " " {
                x += wordSpace
                pendingGap = false
                continue
            }
            guard let glyph = glyphs[character] else {
                throw DrillError("Text can use letters, numbers and . , ' ! ? - + / & # — not “\(character)”.")
            }
            if pendingGap { x += letterGap }
            let points = glyph.flatMap { $0 }
            let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
            // Narrow marks such as "." and "!" get a one-unit cell, centered, so they still have width.
            let cell = max(maxX - minX, 1), inset = (cell - (maxX - minX)) / 2
            strokes += glyph.map { $0.map { Point2($0.x - minX + inset + x, $0.y) } }
            x += cell
            pendingGap = true
        }
        return (strokes, x)
    }
}

/// Text spelled with performers along a baseline from `start` to `end`. The
/// letters stand on the baseline and grow to fill its length, so dragging
/// right to left turns the text upside down and a slanted drag slants it.
public struct TextShape: Hashable, Codable, Sendable {
    public static let maxLength = 40

    public var text: String
    public var start: Point2
    public var end: Point2

    public init(_ text: String, start: Point2, end: Point2) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// The text without surrounding spaces, checked for supported characters and length.
    public static func validated(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DrillError("Type the text to spell first.") }
        guard trimmed.count <= maxLength else { throw DrillError("Text can be at most \(maxLength) characters.") }
        _ = try StrokeFont.layout(trimmed)
        return trimmed
    }

    /// Letter height in meters.
    public var height: Double {
        guard let width = try? StrokeFont.layout(text).width, width > 0 else { return 0 }
        return start.distance(to: end) / width * StrokeFont.capHeight
    }

    /// Letter strokes in world meters.
    public func strokes() throws -> [[Point2]] {
        let layout = try StrokeFont.layout(text)
        let length = start.distance(to: end)
        guard !layout.strokes.isEmpty, layout.width > 0, length > 1e-9 else {
            throw DrillError("Drag to give the text a width.")
        }
        let scale = length / layout.width
        let along = (end - start) / length, up = along.perpendicular
        return layout.strokes.map { $0.map { start + along * ($0.x * scale) + up * ($0.y * scale) } }
    }

    /// Fewest performers that still show every stroke: both ends of each line
    /// and three around each closed loop.
    public func minimumCount() throws -> Int {
        Self.sample(try strokes(), spacing: .infinity).count
    }

    /// Dots at roughly `spacing` along the strokes, with shared joints counted once.
    public func capacity(spacing: Double) throws -> Int {
        Self.sample(try strokes(), spacing: spacing).count
    }

    /// Exactly `count` dots spread evenly along the strokes. The spacing is the
    /// widest that does not need more than `count` dots; the rest fill the largest gaps.
    public func points(_ count: Int) throws -> [Point2] {
        let strokes = try strokes()
        let minimum = Self.sample(strokes, spacing: .infinity)
        guard count >= minimum.count else {
            throw DrillError("“\(text)” needs at least \(minimum.count) performers to read clearly.")
        }
        let total = strokes.reduce(0) { $0 + Self.length($1) }
        var low = total / Double(count * 8 + 8), high = total + 1
        var best = minimum
        if Self.sample(strokes, spacing: low).count <= count {
            best = Self.sample(strokes, spacing: low)
        } else {
            for _ in 0..<48 {
                let mid = (low + high) / 2
                let dots = Self.sample(strokes, spacing: mid)
                if dots.count > count { low = mid } else { high = mid; best = dots }
            }
        }
        return try Self.fill(best, to: count, strokes: strokes)
    }

    // MARK: Sampling

    private struct Dot {
        var stroke: Int
        /// Distance along the stroke.
        var t: Double
        var point: Point2
    }

    private static func length(_ stroke: [Point2]) -> Double {
        zip(stroke, stroke.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    private static func point(_ stroke: [Point2], at t: Double) -> Point2 {
        var remaining = t
        for (a, b) in zip(stroke, stroke.dropFirst()) {
            let d = a.distance(to: b)
            if remaining <= d, d > 0 { return a.lerp(to: b, remaining / d) }
            remaining -= d
        }
        return stroke.last ?? .zero
    }

    private static func isClosed(_ stroke: [Point2]) -> Bool {
        stroke.count > 2 && stroke.first!.distance(to: stroke.last!) < 1e-9
    }

    /// Dots at about `spacing` along each stroke; a dot closer than half a
    /// spacing to one already kept (where strokes meet) is dropped.
    private static func sample(_ strokes: [[Point2]], spacing: Double) -> [Dot] {
        // Dots closer than half a spacing crowd each other where strokes cross or
        // meet. With unbounded spacing the shortest straight run sets the scale instead.
        let runs = strokes.flatMap { s in zip(s, s.dropFirst()).map { $0.distance(to: $1) } }.filter { $0 > 1e-9 }
        let tolerance = spacing.isFinite ? 0.5 * spacing : 0.45 * (runs.min() ?? 1)
        var kept: [Dot] = []
        var grid: [Int64: [Int]] = [:]
        let cell = max(tolerance, 1e-6)
        func key(_ x: Int64, _ y: Int64) -> Int64 { x &* 1_000_003 &+ y }
        func add(_ dot: Dot) {
            let cx = Int64((dot.point.x / cell).rounded(.down)), cy = Int64((dot.point.y / cell).rounded(.down))
            for x in cx - 1...cx + 1 {
                for y in cy - 1...cy + 1 {
                    for i in grid[key(x, y)] ?? [] where kept[i].point.distance(to: dot.point) < tolerance { return }
                }
            }
            grid[key(cx, cy), default: []].append(kept.count)
            kept.append(dot)
        }
        for (index, stroke) in strokes.enumerated() {
            let total = length(stroke)
            guard total > 1e-9 else {
                if let p = stroke.first { add(Dot(stroke: index, t: 0, point: p)) }
                continue
            }
            if isClosed(stroke) {
                let k = spacing.isFinite ? max(3, Int((total / spacing).rounded())) : 3
                for i in 0..<k { add(Dot(stroke: index, t: total * Double(i) / Double(k), point: point(stroke, at: total * Double(i) / Double(k)))) }
            } else {
                let k = spacing.isFinite ? max(2, Int((total / spacing).rounded()) + 1) : 2
                for i in 0..<k {
                    let t = total * Double(i) / Double(k - 1)
                    add(Dot(stroke: index, t: t, point: point(stroke, at: t)))
                }
            }
        }
        return kept
    }

    /// Adds dots at the middle of the largest gaps along any stroke until there are `count`.
    private static func fill(_ dots: [Dot], to count: Int, strokes: [[Point2]]) throws -> [Point2] {
        var byStroke = [[Double]](repeating: [], count: strokes.count)
        for dot in dots { byStroke[dot.stroke].append(dot.t) }
        for i in byStroke.indices { byStroke[i].sort() }
        var points = dots.map(\.point)
        while points.count < count {
            var gaps: [(stroke: Int, t: Double, gap: Double)] = []
            for (i, ts) in byStroke.enumerated() where !ts.isEmpty {
                let total = length(strokes[i])
                var pairs = zip(ts, ts.dropFirst()).map { ($0, $1 - $0) }
                if isClosed(strokes[i]) { pairs.append((ts.last!, ts.first! + total - ts.last!)) }
                for (t0, gap) in pairs where gap > 1e-9 {
                    gaps.append((i, (t0 + gap / 2).truncatingRemainder(dividingBy: max(total, 1e-12)), gap))
                }
            }
            gaps.sort { $0.gap != $1.gap ? $0.gap > $1.gap : ($0.stroke, $0.t) < ($1.stroke, $1.t) }
            // Skip a gap whose middle lands on another stroke, such as where an X crosses.
            let open = gaps.first { gap in
                let p = point(strokes[gap.stroke], at: gap.t)
                return points.allSatisfy { $0.distance(to: p) >= gap.gap / 4 }
            }
            guard let best = open ?? gaps.first else { throw DrillError("There is no room on these strokes for more performers.") }
            byStroke[best.stroke].append(best.t)
            byStroke[best.stroke].sort()
            points.append(point(strokes[best.stroke], at: best.t))
        }
        return points
    }
}
