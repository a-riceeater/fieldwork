/// Exact rational number used for notated durations, pulse positions and
/// cursor fractions. Always normalized with a positive denominator.
public struct Rational: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let numerator: Int64
    public let denominator: Int64

    public init(_ numerator: Int64, _ denominator: Int64 = 1) {
        precondition(denominator != 0, "Rational denominator must not be zero")
        let sign: Int64 = denominator < 0 ? -1 : 1
        let divisor = Rational.gcd(abs(numerator), abs(denominator))
        self.numerator = sign * numerator / divisor
        self.denominator = sign * denominator / divisor
    }

    public init(_ value: Int) { self.init(Int64(value), 1) }

    public static let zero = Rational(0)
    public static let one = Rational(1)

    public var doubleValue: Double { Double(numerator) / Double(denominator) }
    public var isZero: Bool { numerator == 0 }
    public var isInteger: Bool { denominator == 1 }
    /// Largest integer not greater than the value.
    public var floor: Int64 {
        numerator >= 0 ? numerator / denominator : -((-numerator + denominator - 1) / denominator)
    }

    public var description: String { denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)" }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }

    public static func + (l: Rational, r: Rational) -> Rational {
        let g = gcd(l.denominator, r.denominator)
        return Rational(l.numerator * (r.denominator / g) + r.numerator * (l.denominator / g), l.denominator / g * r.denominator)
    }
    public static func - (l: Rational, r: Rational) -> Rational { l + Rational(-r.numerator, r.denominator) }
    public static func * (l: Rational, r: Rational) -> Rational {
        let g1 = gcd(abs(l.numerator), r.denominator)
        let g2 = gcd(abs(r.numerator), l.denominator)
        return Rational((l.numerator / g1) * (r.numerator / g2), (l.denominator / g2) * (r.denominator / g1))
    }
    public static func / (l: Rational, r: Rational) -> Rational {
        precondition(r.numerator != 0, "Division by zero rational")
        return l * Rational(r.denominator, r.numerator)
    }
    public static prefix func - (v: Rational) -> Rational { Rational(-v.numerator, v.denominator) }
    public static func += (l: inout Rational, r: Rational) { l = l + r }
    public static func -= (l: inout Rational, r: Rational) { l = l - r }

    public static func < (l: Rational, r: Rational) -> Bool {
        // Compare via cross multiplication; denominators are positive.
        l.numerator * r.denominator < r.numerator * l.denominator
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let n = try c.decode(Int64.self)
        let d = try c.decode(Int64.self)
        guard d != 0 else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Zero denominator")
        }
        self.init(n, d)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(numerator)
        try c.encode(denominator)
    }
}

/// Common note values expressed as fractions of a whole note.
public enum NoteValue {
    public static let whole = Rational(1, 1)
    public static let half = Rational(1, 2)
    public static let dottedHalf = Rational(3, 4)
    public static let quarter = Rational(1, 4)
    public static let dottedQuarter = Rational(3, 8)
    public static let eighth = Rational(1, 8)
    public static let sixteenth = Rational(1, 16)
}
