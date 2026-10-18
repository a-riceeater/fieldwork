import Foundation
import DrillTiming

/// A reference line on the field used for drawing and coordinate descriptions.
public struct Checkpoint: Hashable, Codable, Sendable {
    public enum Axis: String, Codable, Sendable {
        /// A line of constant x (yard line); describes side-to-side position.
        case x
        /// A line of constant y (sideline, hash); describes front-to-back position.
        case y
    }

    public enum Prominence: String, Codable, Sendable { case major, minor, hash }

    public var axis: Axis
    public var position: Double
    public var label: String
    public var prominence: Prominence

    public init(axis: Axis, position: Double, label: String, prominence: Prominence) {
        self.axis = axis
        self.position = position
        self.label = label
        self.prominence = prominence
    }
}

/// Field geometry in meters. Canonical coordinates are world meters with the
/// origin at field center; steps, yards and labels are views over them.
public struct Field: Hashable, Codable, Sendable {
    public enum Preset: String, Codable, Sendable, CaseIterable {
        case highSchoolFootball
        case collegeFootball
        case proFootball
        case indoorFloor
        case custom

        public var displayName: String {
            switch self {
            case .highSchoolFootball: return "High school football"
            case .collegeFootball: return "College football"
            case .proFootball: return "Pro football"
            case .indoorFloor: return "Indoor floor (90 × 60 ft)"
            case .custom: return "Custom"
            }
        }
    }

    public var name: String
    public var preset: Preset
    /// Side-to-side extent (x), meters.
    public var length: Double
    /// Front-to-back extent (y), meters.
    public var width: Double
    /// Length of one marching step, meters (8-to-5 = 0.5715).
    public var stepSize: Double
    public var checkpoints: [Checkpoint]
    /// Labels for the audience-left and audience-right halves.
    public var sideLabels: [String]
    public var frontLabel: String
    public var backLabel: String

    public init(name: String, preset: Preset, length: Double, width: Double, stepSize: Double, checkpoints: [Checkpoint],
                sideLabels: [String] = ["S1", "S2"], frontLabel: String = "front", backLabel: String = "back") {
        self.name = name
        self.preset = preset
        self.length = length
        self.width = width
        self.stepSize = stepSize
        self.checkpoints = checkpoints
        self.sideLabels = sideLabels
        self.frontLabel = frontLabel
        self.backLabel = backLabel
    }

    public static let yard = 0.9144
    public static let foot = 0.3048
    public static let eightToFive = 5 * yard / 8

    public var bounds: Rect2 { Rect2(minX: -length / 2, minY: -width / 2, maxX: length / 2, maxY: width / 2) }

    public static func make(_ preset: Preset) -> Field {
        switch preset {
        case .highSchoolFootball: return football(name: preset.displayName, preset: preset, hashFromSideline: 53 * foot + 4 * foot / 12)
        case .collegeFootball: return football(name: preset.displayName, preset: preset, hashFromSideline: 60 * foot)
        case .proFootball: return football(name: preset.displayName, preset: preset, hashFromSideline: 70 * foot + 9 * foot / 12)
        case .indoorFloor: return indoor(lengthFeet: 90, widthFeet: 60)
        case .custom: return custom(length: 40, width: 30, stepSize: eightToFive)
        }
    }

    /// A 120 × 53⅓ yd football field including end zones, yard lines every 5 yd.
    public static func football(name: String, preset: Preset, hashFromSideline: Double) -> Field {
        let length = 120 * yard
        let width = 160 * foot
        var checkpoints: [Checkpoint] = []
        for yardLine in stride(from: -50, through: 50, by: 5) {
            let x = Double(yardLine) * yard
            let fromGoal = 50 - abs(yardLine)
            let label = fromGoal == 0 ? "G" : String(fromGoal)
            checkpoints.append(Checkpoint(axis: .x, position: x, label: label, prominence: yardLine % 10 == 0 ? .major : .minor))
        }
        checkpoints.append(Checkpoint(axis: .x, position: -length / 2, label: "S1 end line", prominence: .major))
        checkpoints.append(Checkpoint(axis: .x, position: length / 2, label: "S2 end line", prominence: .major))
        checkpoints.append(Checkpoint(axis: .y, position: -width / 2, label: "front sideline", prominence: .major))
        checkpoints.append(Checkpoint(axis: .y, position: -width / 2 + hashFromSideline, label: "front hash", prominence: .hash))
        checkpoints.append(Checkpoint(axis: .y, position: width / 2 - hashFromSideline, label: "back hash", prominence: .hash))
        checkpoints.append(Checkpoint(axis: .y, position: width / 2, label: "back sideline", prominence: .major))
        return Field(name: name, preset: preset, length: length, width: width, stepSize: eightToFive, checkpoints: checkpoints)
    }

    public static func indoor(lengthFeet: Double, widthFeet: Double) -> Field {
        let length = lengthFeet * foot, width = widthFeet * foot
        var checkpoints: [Checkpoint] = []
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var i = 0
        for x in stride(from: -length / 2, through: length / 2 + 1e-9, by: 10 * foot) {
            checkpoints.append(Checkpoint(axis: .x, position: x, label: String(letters[i % letters.count]), prominence: i % 3 == 0 ? .major : .minor))
            i += 1
        }
        checkpoints.append(Checkpoint(axis: .y, position: -width / 2, label: "front edge", prominence: .major))
        checkpoints.append(Checkpoint(axis: .y, position: 0, label: "center line", prominence: .hash))
        checkpoints.append(Checkpoint(axis: .y, position: width / 2, label: "back edge", prominence: .major))
        return Field(name: Preset.indoorFloor.displayName, preset: .indoorFloor, length: length, width: width, stepSize: eightToFive, checkpoints: checkpoints)
    }

    /// Custom rectangle with reference lines every 8 steps.
    public static func custom(length: Double, width: Double, stepSize: Double, name: String = "Custom field") -> Field {
        var checkpoints: [Checkpoint] = []
        let spacing = 8 * stepSize
        var n = 0
        var x = 0.0
        while x <= length / 2 + 1e-9 {
            for sx in x == 0 ? [0.0] : [-x, x] {
                checkpoints.append(Checkpoint(axis: .x, position: sx, label: x == 0 ? "C" : String(n), prominence: n % 2 == 0 ? .major : .minor))
            }
            n += 1
            x = Double(n) * spacing
        }
        checkpoints.append(Checkpoint(axis: .y, position: -width / 2, label: "front edge", prominence: .major))
        checkpoints.append(Checkpoint(axis: .y, position: 0, label: "center", prominence: .hash))
        checkpoints.append(Checkpoint(axis: .y, position: width / 2, label: "back edge", prominence: .major))
        return Field(name: name, preset: .custom, length: length, width: width, stepSize: stepSize, checkpoints: checkpoints)
    }

    public func validate() throws {
        guard length.isFinite, width.isFinite, length >= 2, width >= 2, length <= 1000, width <= 1000 else {
            throw DrillError("Field dimensions must be between 2 and 1000 meters.")
        }
        guard stepSize.isFinite, stepSize > 0.05, stepSize < 5 else { throw DrillError("Step size must be between 0.05 and 5 meters.") }
    }

    /// Snaps a point to the nearest multiple of `steps` × step size from field center.
    public func snap(_ p: Point2, steps: Double) -> Point2 {
        let grid = steps * stepSize
        guard grid > 0 else { return p }
        return Point2((p.x / grid).rounded() * grid, (p.y / grid).rounded() * grid)
    }
}

/// Describes world positions relative to field checkpoints, e.g.
/// "S1: 4.0 outside 35" and "8.0 behind front hash".
public struct CoordinateDescriber: Sendable {
    public var field: Field
    /// Rounding increment in steps (0.25 = quarter step).
    public var rounding: Double

    public init(field: Field, rounding: Double = 0.25) {
        self.field = field
        self.rounding = rounding
    }

    func steps(_ meters: Double) -> String {
        let s = (meters / field.stepSize / rounding).rounded() * rounding
        return TimeFormat.decimal(s, places: rounding >= 1 ? 0 : (rounding >= 0.5 ? 1 : 2))
    }

    func isZero(_ meters: Double) -> Bool { (meters / field.stepSize / rounding).rounded() == 0 }

    /// Side-to-side description relative to the nearest x checkpoint.
    public func sideToSide(_ x: Double) -> String {
        let lines = field.checkpoints.filter { $0.axis == .x && $0.prominence != .hash && !$0.label.hasSuffix("end line") }
        guard let nearest = lines.min(by: { abs($0.position - x) < abs($1.position - x) }) else { return "x " + steps(x) }
        let side = x < 0 ? field.sideLabels.first ?? "S1" : field.sideLabels.last ?? "S2"
        let delta = x - nearest.position
        let onCenter = abs(nearest.position) < 1e-6
        if isZero(delta) {
            return onCenter ? "On \(nearest.label)" : "\(side): On \(nearest.label)"
        }
        // Inside means toward field center; everything off the center line is outside it.
        let inside = abs(x) < abs(nearest.position)
        return "\(side): \(steps(abs(delta))) \(inside ? "inside" : "outside") \(nearest.label)"
    }

    /// Front-to-back description relative to the nearest y checkpoint.
    public func frontToBack(_ y: Double) -> String {
        let lines = field.checkpoints.filter { $0.axis == .y }
        guard let nearest = lines.min(by: { abs($0.position - y) < abs($1.position - y) }) else { return "y " + steps(y) }
        let delta = y - nearest.position
        if isZero(delta) { return "On \(nearest.label)" }
        return "\(steps(abs(delta))) \(delta > 0 ? "behind" : "in front of") \(nearest.label)"
    }
}
