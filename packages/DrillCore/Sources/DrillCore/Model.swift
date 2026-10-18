import Foundation
import DrillTiming

public enum ShowTag {}
public enum MovementTag {}
public enum SectionTag {}
public enum PerformerTag {}
public enum SetTag {}
public enum TransitionTag {}
public enum FormTag {}

public typealias ShowID = TypedID<ShowTag>
public typealias MovementID = TypedID<MovementTag>
public typealias SectionID = TypedID<SectionTag>
public typealias PerformerID = TypedID<PerformerTag>
public typealias SetID = TypedID<SetTag>
public typealias TransitionID = TypedID<TransitionTag>
public typealias FormID = TypedID<FormTag>

public struct DrillError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// World position of a performer at an arrival. Facing is in degrees,
/// 0 = toward the front sideline (audience), increasing clockwise seen from above
/// (90 = toward the audience's right).
public struct Position: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var facing: Double

    public init(x: Double, y: Double, z: Double = 0, facing: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
        self.facing = facing
    }

    public init(_ p: Point2, facing: Double = 0) { self.init(x: p.x, y: p.y, facing: facing) }

    public var point: Point2 {
        get { Point2(x, y) }
        set { x = newValue.x; y = newValue.y }
    }
}

/// A performer's state at an arrival. Missing data is explicit; nothing defaults to (0, 0).
public enum Placement: Hashable, Codable, Sendable {
    case placed(Position)
    case unresolved
    case inactive

    public var position: Position? {
        if case .placed(let p) = self { return p }
        return nil
    }
}

public enum PerformerSymbol: String, Codable, Sendable, CaseIterable {
    case circle, cross, square, triangle, diamond, slash
}

public struct Section: Hashable, Codable, Sendable, Identifiable {
    public var id: SectionID
    public var name: String
    /// Drill label prefix, e.g. "T" for trumpets.
    public var prefix: String
    public var symbol: PerformerSymbol
    /// Index into the shared section palette (design tokens), not a raw color.
    public var colorIndex: Int

    public init(id: SectionID = SectionID(), name: String, prefix: String, symbol: PerformerSymbol = .circle, colorIndex: Int = 0) {
        self.id = id
        self.name = name
        self.prefix = prefix
        self.symbol = symbol
        self.colorIndex = colorIndex
    }
}

public struct Performer: Hashable, Codable, Sendable, Identifiable {
    public var id: PerformerID
    /// Drill label shown on the field, e.g. "T3".
    public var label: String
    public var sectionID: SectionID
    /// Optional private roster name; stripped from public exports unless requested.
    public var name: String?
    public var notes: String

    public init(id: PerformerID = PerformerID(), label: String, sectionID: SectionID, name: String? = nil, notes: String = "") {
        self.id = id
        self.label = label
        self.sectionID = sectionID
        self.name = name
        self.notes = notes
    }
}

/// An exact formation at a timeline cursor. The first set of a movement is the
/// preset (count 0); every later set has an incoming transition.
public struct ArrivalSet: Hashable, Codable, Sendable, Identifiable {
    public var id: SetID
    public var movementID: MovementID
    public var label: String
    public var cursor: TimelineCursor
    public var isSubset: Bool
    public var notes: String
    /// Rehearsal mark that starts at this set, such as "A" or "CC". Empty for none.
    public var rehearsalMark: String
    /// Author-entered measure reference, such as "222-223". Empty for none;
    /// in measures mode the computed position is shown instead.
    public var measureMarker: String

    public init(id: SetID = SetID(), movementID: MovementID, label: String, cursor: TimelineCursor, isSubset: Bool = false, notes: String = "",
                rehearsalMark: String = "", measureMarker: String = "") {
        self.id = id
        self.movementID = movementID
        self.label = label
        self.cursor = cursor
        self.isSubset = isSubset
        self.notes = notes
        self.rehearsalMark = rehearsalMark
        self.measureMarker = measureMarker
    }

    /// Accepts sets written before rehearsal marks and measure markers existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SetID.self, forKey: .id)
        movementID = try c.decode(MovementID.self, forKey: .movementID)
        label = try c.decode(String.self, forKey: .label)
        cursor = try c.decode(TimelineCursor.self, forKey: .cursor)
        isSubset = try c.decode(Bool.self, forKey: .isSubset)
        notes = try c.decode(String.self, forKey: .notes)
        rehearsalMark = try c.decodeIfPresent(String.self, forKey: .rehearsalMark) ?? ""
        measureMarker = try c.decodeIfPresent(String.self, forKey: .measureMarker) ?? ""
    }
}

/// How sets relate to the music. In `measures` mode set positions are shown
/// as measures and beats from the timeline; in `counts` mode sets are pages of
/// counts and any measure numbers are markers the author types in.
public enum CountingMode: String, Codable, Sendable, CaseIterable {
    case measures, counts

    public var displayName: String {
        switch self {
        case .measures: return "Follow measures"
        case .counts: return "Counts only"
        }
    }
}

/// Placements of every performer at one set. A missing key means unresolved.
public struct Formation: Hashable, Codable, Sendable {
    public var placements: [PerformerID: Placement]

    public init(placements: [PerformerID: Placement] = [:]) { self.placements = placements }

    public subscript(_ id: PerformerID) -> Placement {
        get { placements[id] ?? .unresolved }
        set { placements[id] = newValue }
    }
}

public enum TransitionModel: String, Codable, Sendable {
    /// Straight travel at constant speed over the move's counts.
    case straight
}

/// Travel from the previous arrival into `toSetID`.
public struct Transition: Hashable, Codable, Sendable, Identifiable {
    public var id: TransitionID
    public var toSetID: SetID
    public var model: TransitionModel

    public init(id: TransitionID = TransitionID(), toSetID: SetID, model: TransitionModel = .straight) {
        self.id = id
        self.toSetID = toSetID
        self.model = model
    }
}

/// A form instance on one set: control geometry plus ordered membership.
public struct Form: Hashable, Codable, Sendable, Identifiable {
    public var id: FormID
    public var setID: SetID
    public var geometry: FormGeometry
    /// Assignment order along the form.
    public var members: [PerformerID]

    public init(id: FormID = FormID(), setID: SetID, geometry: FormGeometry, members: [PerformerID]) {
        self.id = id
        self.setID = setID
        self.geometry = geometry
        self.members = members
    }

    public func positions() -> [PerformerID: Point2] {
        Dictionary(uniqueKeysWithValues: zip(members, geometry.distribute(members.count)))
    }
}

public struct Movement: Hashable, Codable, Sendable, Identifiable {
    public var id: MovementID
    public var name: String
    public var timing: TimingTrack
    /// Audio asset that supplies the playback clock for this movement.
    public var audioAssetID: MediaAssetID?

    public init(id: MovementID = MovementID(), name: String, timing: TimingTrack, audioAssetID: MediaAssetID? = nil) {
        self.id = id
        self.name = name
        self.timing = timing
        self.audioAssetID = audioAssetID
    }
}

/// Metadata for an embedded media file. Bytes live in the document's asset
/// store keyed by content hash, outside the undoable model.
public struct MediaAssetInfo: Hashable, Codable, Sendable, Identifiable {
    public var id: MediaAssetID
    public var sha256: String
    public var fileExtension: String
    public var originalFilename: String
    public var byteCount: Int64
    public var sampleRate: Double
    public var frameCount: Int64
    public var channelCount: Int

    public init(id: MediaAssetID = MediaAssetID(), sha256: String, fileExtension: String, originalFilename: String, byteCount: Int64,
                sampleRate: Double, frameCount: Int64, channelCount: Int) {
        self.id = id
        self.sha256 = sha256
        self.fileExtension = fileExtension
        self.originalFilename = originalFilename
        self.byteCount = byteCount
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.channelCount = channelCount
    }

    public var archivePath: String { "assets/\(sha256).\(fileExtension)" }
    public var durationSeconds: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
}

/// Design-aid thresholds for analysis warnings.
public struct AnalysisSettings: Hashable, Codable, Sendable {
    /// Largest stride per count before warning, meters (default 6-to-5).
    public var maxStride: Double
    /// Closest allowed pass between two moving performers, meters.
    public var minClearance: Double

    public init(maxStride: Double = 5 * Field.yard / 6, minClearance: Double = 0.5) {
        self.maxStride = maxStride
        self.minClearance = minClearance
    }
}

/// The complete authored show. Selection, tour progress and other view state
/// are deliberately not part of this model.
public struct Show: Hashable, Codable, Sendable {
    public var id: ShowID
    public var title: String
    public var field: Field
    public var sections: [Section]
    public var performers: [Performer]
    public var movements: [Movement]
    /// All sets of all movements, ordered by timeline within each movement.
    public var sets: [ArrivalSet]
    public var formations: [SetID: Formation]
    public var transitions: [Transition]
    public var forms: [Form]
    public var mediaAssets: [MediaAssetInfo]
    public var analysis: AnalysisSettings
    public var countingMode: CountingMode

    public init(id: ShowID = ShowID(), title: String, field: Field, sections: [Section] = [], performers: [Performer] = [],
                movements: [Movement], sets: [ArrivalSet], formations: [SetID: Formation] = [:], transitions: [Transition] = [],
                forms: [Form] = [], mediaAssets: [MediaAssetInfo] = [], analysis: AnalysisSettings = AnalysisSettings(),
                countingMode: CountingMode = .measures) {
        self.id = id
        self.title = title
        self.field = field
        self.sections = sections
        self.performers = performers
        self.movements = movements
        self.sets = sets
        self.formations = formations
        self.transitions = transitions
        self.forms = forms
        self.mediaAssets = mediaAssets
        self.analysis = analysis
        self.countingMode = countingMode
    }

    /// Accepts shows written before the counting mode existed (they follow measures).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ShowID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        field = try c.decode(Field.self, forKey: .field)
        sections = try c.decode([Section].self, forKey: .sections)
        performers = try c.decode([Performer].self, forKey: .performers)
        movements = try c.decode([Movement].self, forKey: .movements)
        sets = try c.decode([ArrivalSet].self, forKey: .sets)
        formations = try c.decode([SetID: Formation].self, forKey: .formations)
        transitions = try c.decode([Transition].self, forKey: .transitions)
        forms = try c.decode([Form].self, forKey: .forms)
        mediaAssets = try c.decode([MediaAssetInfo].self, forKey: .mediaAssets)
        analysis = try c.decode(AnalysisSettings.self, forKey: .analysis)
        countingMode = try c.decodeIfPresent(CountingMode.self, forKey: .countingMode) ?? .measures
    }

    /// The set's place in the music as shown in lists and printouts: the
    /// author's measure marker when present, otherwise the computed measure and
    /// beat in measures mode, or nothing in counts mode.
    public func measureLabel(for set: ArrivalSet, map: TimingMap?) -> String {
        let marker = set.measureMarker.trimmingCharacters(in: .whitespaces)
        if !marker.isEmpty { return marker.first?.isNumber == true ? "m. \(marker)" : marker }
        guard countingMode == .measures, let map else { return "" }
        return (try? map.musicalPosition(at: set.cursor).label) ?? ""
    }

    /// Counts from the start of the movement to the set's arrival.
    public func cumulativeCount(of set: ArrivalSet, map: TimingMap?) -> Rational? {
        guard let map else { return nil }
        return try? map.pulse(at: set.cursor)
    }

    /// A valid empty show: one movement with a counts-only 4/4 timeline and a preset.
    public static func makeNew(title: String, field: Field = .make(.highSchoolFootball), meter: Meter = Meter(4, 4), bpm: Double = 120,
                               measures: Int = 32, showID: ShowID = ShowID(), movementID: MovementID = MovementID(), presetID: SetID = SetID()) throws -> Show {
        let track = try TimingTrack.make(meter: meter, bpm: bpm, measures: measures)
        let movement = Movement(id: movementID, name: "Movement 1", timing: track)
        let preset = ArrivalSet(id: presetID, movementID: movement.id, label: "1", cursor: TimelineCursor(eventID: track.events[0].id))
        return Show(id: showID, title: title, field: field, movements: [movement], sets: [preset], formations: [preset.id: Formation()])
    }

    // MARK: Lookup helpers

    public func movement(_ id: MovementID) -> Movement? { movements.first { $0.id == id } }
    public func set(_ id: SetID) -> ArrivalSet? { sets.first { $0.id == id } }
    public func performer(_ id: PerformerID) -> Performer? { performers.first { $0.id == id } }
    public func section(_ id: SectionID) -> Section? { sections.first { $0.id == id } }
    public func sets(in movement: MovementID) -> [ArrivalSet] { sets.filter { $0.movementID == movement } }
    public func formation(_ set: SetID) -> Formation { formations[set] ?? Formation() }
    public func transition(into set: SetID) -> Transition? { transitions.first { $0.toSetID == set } }
    public func form(_ id: FormID) -> Form? { forms.first { $0.id == id } }
    public func forms(on set: SetID) -> [Form] { forms.filter { $0.setID == set } }
    public func performers(in section: SectionID) -> [Performer] { performers.filter { $0.sectionID == section } }

    public func timingMap(for movementID: MovementID) throws -> TimingMap {
        guard let movement = movement(movementID) else { throw DrillError("Unknown movement.") }
        return try TimingMap(track: movement.timing, assetID: movement.audioAssetID)
    }

    /// Count position of every set in a movement, in timeline order.
    public func setPulses(in movementID: MovementID, map: TimingMap? = nil) throws -> [(set: ArrivalSet, pulse: Rational)] {
        let map = try map ?? timingMap(for: movementID)
        return try sets(in: movementID).map { ($0, try map.pulse(at: $0.cursor)) }
    }

    /// The previous set in the same movement, if any.
    public func previousSet(before id: SetID) -> ArrivalSet? {
        guard let set = set(id) else { return nil }
        let list = sets(in: set.movementID)
        guard let i = list.firstIndex(where: { $0.id == id }), i > 0 else { return nil }
        return list[i - 1]
    }

    public func nextSet(after id: SetID) -> ArrivalSet? {
        guard let set = set(id) else { return nil }
        let list = sets(in: set.movementID)
        guard let i = list.firstIndex(where: { $0.id == id }), i + 1 < list.count else { return nil }
        return list[i + 1]
    }

    /// Counts in the move into a set (0 for a preset).
    public func moveCounts(into id: SetID) throws -> Rational {
        guard let set = set(id) else { throw DrillError("Unknown set.") }
        guard let previous = previousSet(before: id) else { return .zero }
        let map = try timingMap(for: set.movementID)
        return try map.pulse(at: set.cursor) - map.pulse(at: previous.cursor)
    }

    /// Suggested label for a new performer in a section, e.g. "T4".
    public func nextLabel(in section: Section) -> String {
        let used = Set(performers.filter { $0.sectionID == section.id }.map(\.label))
        var n = 1
        while used.contains("\(section.prefix)\(n)") { n += 1 }
        return "\(section.prefix)\(n)"
    }
}
