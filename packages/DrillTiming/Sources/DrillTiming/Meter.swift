/// A notated meter. `grouping` optionally lists beat groups in denominator
/// units (for example `[3, 2]` in 5/8); when present it defines the march
/// count pulses inside each measure instead of the pulse unit.
public struct Meter: Hashable, Codable, Sendable, CustomStringConvertible {
    public var numerator: Int
    public var denominator: Int
    public var grouping: [Int]?

    public init(_ numerator: Int, _ denominator: Int, grouping: [Int]? = nil) {
        self.numerator = numerator
        self.denominator = denominator
        self.grouping = grouping
    }

    public var isValid: Bool {
        guard numerator > 0, denominator > 0, denominator & (denominator - 1) == 0 else { return false }
        if let grouping { return grouping.allSatisfy { $0 > 0 } && grouping.reduce(0, +) == numerator }
        return true
    }

    /// Duration of one notated beat (one denominator unit) in whole notes.
    public var beatUnit: Rational { Rational(1, Int64(denominator)) }
    /// Duration of a full measure in whole notes.
    public var measureLength: Rational { Rational(Int64(numerator), Int64(denominator)) }

    public var description: String { "\(numerator)/\(denominator)" }
}
