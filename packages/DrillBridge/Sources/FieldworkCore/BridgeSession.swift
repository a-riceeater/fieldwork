import Foundation
import DrillTiming
import DrillCore
import DrillDocument

/// JSON command shapes accepted over the C ABI. Performers are addressed by
/// drill label or ID; sets by timeline index within the first movement.
struct BridgeCommand: Decodable {
    var type: String
    var title: String?
    var name: String?
    var prefix: String?
    var count: Int?
    var preset: String?
    var set: Int?
    var after: Int?
    var counts: Int?
    var performer: String?
    var performers: [String]?
    var x: Double?, y: Double?
    var dx: Double?, dy: Double?
    var x0: Double?, y0: Double?, x1: Double?, y1: Double?
    var bulge: Double?
}

struct BridgeFailure: Error {
    var status: Int32
    var message: String
}

/// One core session behind an opaque handle. All access is serialized by `lock`.
final class BridgeSession: @unchecked Sendable {
    let lock = NSLock()
    let session: DocumentSession
    var assets: [String: Data]

    init(show: Show, assets: [String: Data] = [:]) throws {
        session = try DocumentSession(show: show)
        self.assets = assets
    }

    func setID(_ index: Int?) throws -> SetID {
        let sets = session.show.sets(in: session.show.movements[0].id)
        let i = index ?? 0
        guard sets.indices.contains(i) else { throw BridgeFailure(status: FWStatus.invalidArgument, message: "Set index \(i) does not exist.") }
        return sets[i].id
    }

    func performerID(_ key: String) throws -> PerformerID {
        if let match = session.show.performers.first(where: { $0.label == key || $0.id.description == key }) { return match.id }
        throw BridgeFailure(status: FWStatus.invalidArgument, message: "Unknown performer \(key).")
    }

    func performerIDs(_ keys: [String]?) throws -> [PerformerID] {
        guard let keys else { return session.show.performers.map(\.id) }
        return try keys.map(performerID)
    }

    func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw BridgeFailure(status: FWStatus.invalidArgument, message: "Missing field \(name).") }
        return value
    }

    /// Executes one JSON command and returns a JSON result object.
    func dispatch(_ json: Data) throws -> [String: Any] {
        let command: BridgeCommand
        do { command = try JSONDecoder().decode(BridgeCommand.self, from: json) } catch {
            throw BridgeFailure(status: FWStatus.invalidArgument, message: "Malformed command JSON.")
        }
        let show = session.show
        let drill: DrillCommand?
        switch command.type {
        case "renameShow":
            drill = .renameShow(try require(command.title, "title"))
        case "setField":
            guard let preset = Field.Preset(rawValue: try require(command.preset, "preset")) else {
                throw BridgeFailure(status: FWStatus.invalidArgument, message: "Unknown field preset.")
            }
            drill = .setField(.make(preset))
        case "addSection":
            drill = try show.makeRoster([RosterSectionRequest(name: try require(command.name, "name"), prefix: command.prefix ?? String(command.name!.prefix(1)),
                                                              count: command.count ?? 0)])
        case "addSet":
            drill = try show.makeCreateSet(after: try setID(command.after), counts: try require(command.counts, "counts"))
        case "movePerformer":
            drill = try show.makeSetCoordinate(try performerID(try require(command.performer, "performer")), at: try setID(command.set),
                                               x: try require(command.x, "x"), y: try require(command.y, "y"))
        case "translate":
            drill = try show.makeTranslate(try performerIDs(command.performers), at: try setID(command.set), by: Point2(command.dx ?? 0, command.dy ?? 0))
        case "placeLine", "placeArc":
            let start = Point2(try require(command.x0, "x0"), try require(command.y0, "y0"))
            let end = Point2(try require(command.x1, "x1"), try require(command.y1, "y1"))
            let geometry: FormGeometry = command.type == "placeLine" ? .line(start: start, end: end) : .arc(start: start, end: end, bulge: command.bulge ?? 0)
            drill = try show.makeForm(geometry, members: show.sequentialOrder(try performerIDs(command.performers)), at: try setID(command.set))
        case "undo":
            guard session.undo() != nil else { throw BridgeFailure(status: FWStatus.commandFailed, message: "Nothing to undo.") }
            drill = nil
        case "redo":
            guard session.redo() != nil else { throw BridgeFailure(status: FWStatus.commandFailed, message: "Nothing to redo.") }
            drill = nil
        default:
            throw BridgeFailure(status: FWStatus.invalidArgument, message: "Unknown command type \(command.type).")
        }
        if let drill { try session.perform(drill) }
        return ["ok": true, "revision": session.revision, "undo": session.undoName ?? NSNull(), "redo": session.redoName ?? NSNull()]
    }

    func snapshot() throws -> [String: Any] {
        let show = session.show
        let movement = show.movements[0].id
        let map = try session.timingMap(for: movement)
        let sections = Dictionary(uniqueKeysWithValues: show.sections.map { ($0.id, $0.name) })
        return [
            "title": show.title,
            "revision": session.revision,
            "dirty": session.isDirty,
            "field": ["name": show.field.name, "length": show.field.length, "width": show.field.width, "stepSize": show.field.stepSize],
            "performers": show.performers.map { ["id": $0.id.description, "label": $0.label, "section": sections[$0.sectionID] ?? ""] },
            "sets": try show.sets(in: movement).map { set -> [String: Any] in
                ["id": set.id.description, "label": set.label, "count": try map.pulse(at: set.cursor).doubleValue,
                 "music": try map.musicalPosition(at: set.cursor).label]
            },
            "undo": session.undoName ?? NSNull(),
            "redo": session.redoName ?? NSNull(),
        ]
    }

    func evaluate(pulse: Double) throws -> [String: Any] {
        let evaluator = try SceneEvaluator(show: session.show, movementID: session.show.movements[0].id, map: try session.timingMap(for: session.show.movements[0].id))
        let scene = evaluator.evaluate(pulse: pulse)
        let labels = Dictionary(uniqueKeysWithValues: session.show.performers.map { ($0.id, $0.label) })
        return [
            "pulse": scene.pulse,
            "setIndex": scene.setIndex,
            "progress": scene.progress,
            "performers": scene.performers.map { p -> [String: Any] in
                var row: [String: Any] = ["label": labels[p.id] ?? "", "state": "\(p.state)"]
                if p.state == .placed { row["x"] = p.x; row["y"] = p.y; row["facing"] = p.facing }
                return row
            },
        ]
    }

    func encode() throws -> Data {
        try DocumentCodec.encode(ShowDocument(show: session.show, assets: assets))
    }
}

enum FWStatus {
    static let ok: Int32 = 0
    static let invalidArgument: Int32 = 1
    static let invalidHandle: Int32 = 2
    static let commandFailed: Int32 = 3
    static let decodeFailed: Int32 = 4
    static let internalError: Int32 = 5
}

/// Process-wide registry of sessions keyed by opaque 64-bit handles.
final class BridgeRegistry: @unchecked Sendable {
    static let shared = BridgeRegistry()
    private let lock = NSLock()
    private var sessions: [UInt64: BridgeSession] = [:]
    private var next: UInt64 = 1

    func insert(_ session: BridgeSession) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let handle = next
        next += 1
        sessions[handle] = session
        return handle
    }

    func get(_ handle: UInt64) -> BridgeSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[handle]
    }

    func remove(_ handle: UInt64) {
        lock.lock(); defer { lock.unlock() }
        sessions[handle] = nil
    }
}
