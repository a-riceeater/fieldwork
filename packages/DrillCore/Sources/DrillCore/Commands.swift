import Foundation
import DrillTiming

/// A semantic, fully resolved edit. Commands carry every generated ID so
/// replaying a journal reproduces the same show exactly.
public indirect enum DrillCommand: Hashable, Codable, Sendable {
    case renameShow(String)
    case setField(Field)
    case addSection(Section)
    case updateSection(Section)
    case removeSection(SectionID)
    case addPerformers([Performer], placements: [SetID: [PerformerID: Placement]])
    case removePerformers([PerformerID])
    case updatePerformer(Performer)
    case createSet(ArrivalSet, transition: Transition, formation: Formation)
    case deleteSet(SetID)
    case updateSet(SetID, label: String, notes: String)
    case moveSetCursors([SetID: TimelineCursor])
    case setPlacements(SetID, [PerformerID: Placement])
    case applyForm(Form)
    case updateFormGeometry(FormID, FormGeometry)
    case updateFormMembers(FormID, [PerformerID])
    case detachForm(FormID)
    case replaceTiming(MovementID, TimingTrack)
    case setMovementAudio(MovementID, MediaAssetID?)
    case addMediaAsset(MediaAssetInfo)
    case setAnalysisSettings(AnalysisSettings)
    case batch(String, [DrillCommand])

    /// Undo/redo menu description.
    public var name: String {
        switch self {
        case .renameShow: return "Rename Show"
        case .setField: return "Change Field"
        case .addSection: return "Add Section"
        case .updateSection: return "Edit Section"
        case .removeSection: return "Remove Section"
        case .addPerformers(let p, _): return p.count == 1 ? "Add Performer" : "Add \(p.count) Performers"
        case .removePerformers(let p): return p.count == 1 ? "Remove Performer" : "Remove \(p.count) Performers"
        case .updatePerformer: return "Edit Performer"
        case .createSet: return "Add Set"
        case .deleteSet: return "Delete Set"
        case .updateSet: return "Edit Set"
        case .moveSetCursors: return "Change Set Timing"
        case .setPlacements(_, let p): return p.count == 1 ? "Move Performer" : "Move \(p.count) Performers"
        case .applyForm(let f): return "Apply \(f.geometry.kindName)"
        case .updateFormGeometry(_, let g): return "Edit \(g.kindName)"
        case .updateFormMembers: return "Reorder Form"
        case .detachForm: return "Detach Form"
        case .replaceTiming: return "Edit Timing"
        case .setMovementAudio: return "Set Movement Audio"
        case .addMediaAsset: return "Import Audio"
        case .setAnalysisSettings: return "Change Warning Thresholds"
        case .batch(let name, _): return name
        }
    }

    /// Short machine-readable kind, used by onboarding and diagnostics.
    public var kind: String {
        switch self {
        case .renameShow: return "renameShow"
        case .setField: return "setField"
        case .addSection: return "addSection"
        case .updateSection: return "updateSection"
        case .removeSection: return "removeSection"
        case .addPerformers: return "addPerformers"
        case .removePerformers: return "removePerformers"
        case .updatePerformer: return "updatePerformer"
        case .createSet: return "createSet"
        case .deleteSet: return "deleteSet"
        case .updateSet: return "updateSet"
        case .moveSetCursors: return "moveSetCursors"
        case .setPlacements: return "setPlacements"
        case .applyForm: return "applyForm"
        case .updateFormGeometry: return "updateFormGeometry"
        case .updateFormMembers: return "updateFormMembers"
        case .detachForm: return "detachForm"
        case .replaceTiming: return "replaceTiming"
        case .setMovementAudio: return "setMovementAudio"
        case .addMediaAsset: return "addMediaAsset"
        case .setAnalysisSettings: return "setAnalysisSettings"
        case .batch: return "batch"
        }
    }

    /// Kinds of this command and any nested commands.
    public var allKinds: [String] {
        if case .batch(_, let list) = self { return ["batch"] + list.flatMap(\.allKinds) }
        return [kind]
    }

    /// Applies the command to a copy of the show. Validation of the final
    /// result is performed by the session so a batch commits atomically.
    public func applied(to input: Show) throws -> Show {
        var show = input
        switch self {
        case .renameShow(let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw DrillError("The show title cannot be empty.") }
            show.title = trimmed

        case .setField(let field):
            try field.validate()
            show.field = field

        case .addSection(let section):
            guard show.section(section.id) == nil else { throw DrillError("Section already exists.") }
            guard !section.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw DrillError("Sections need a name.") }
            show.sections.append(section)

        case .updateSection(let section):
            guard let i = show.sections.firstIndex(where: { $0.id == section.id }) else { throw DrillError("Unknown section.") }
            show.sections[i] = section

        case .removeSection(let id):
            guard show.performers(in: id).isEmpty else { throw DrillError("Remove or reassign the section's performers first.") }
            show.sections.removeAll { $0.id == id }

        case .addPerformers(let performers, let placements):
            for p in performers {
                guard show.performer(p.id) == nil else { throw DrillError("Performer already exists.") }
                guard show.section(p.sectionID) != nil else { throw DrillError("Unknown section for \(p.label).") }
            }
            show.performers.append(contentsOf: performers)
            for (setID, values) in placements {
                guard show.set(setID) != nil else { throw DrillError("Unknown set.") }
                var formation = show.formation(setID)
                for (id, placement) in values { formation[id] = placement }
                show.formations[setID] = formation
            }

        case .removePerformers(let ids):
            let remove = Set(ids)
            guard remove.allSatisfy({ show.performer($0) != nil }) else { throw DrillError("Unknown performer.") }
            show.performers.removeAll { remove.contains($0.id) }
            for key in show.formations.keys {
                show.formations[key]!.placements = show.formations[key]!.placements.filter { !remove.contains($0.key) }
            }
            for i in show.forms.indices { show.forms[i].members.removeAll { remove.contains($0) } }
            show.forms.removeAll { $0.members.isEmpty }

        case .updatePerformer(let performer):
            guard let i = show.performers.firstIndex(where: { $0.id == performer.id }) else { throw DrillError("Unknown performer.") }
            show.performers[i] = performer

        case .createSet(let set, let transition, let formation):
            guard show.set(set.id) == nil else { throw DrillError("Set already exists.") }
            guard show.movement(set.movementID) != nil else { throw DrillError("Unknown movement.") }
            guard transition.toSetID == set.id else { throw DrillError("The incoming move must target the new set.") }
            show.sets.append(set)
            show.transitions.append(transition)
            show.formations[set.id] = formation
            try show.sortSets(in: set.movementID)

        case .deleteSet(let id):
            guard let set = show.set(id) else { throw DrillError("Unknown set.") }
            guard show.previousSet(before: id) != nil else { throw DrillError("The preset cannot be deleted. Clear its positions instead.") }
            show.sets.removeAll { $0.id == id }
            show.transitions.removeAll { $0.toSetID == id }
            show.formations[id] = nil
            show.forms.removeAll { $0.setID == id }
            _ = set

        case .updateSet(let id, let label, let notes):
            guard let i = show.sets.firstIndex(where: { $0.id == id }) else { throw DrillError("Unknown set.") }
            guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { throw DrillError("Sets need a label.") }
            show.sets[i].label = label
            show.sets[i].notes = notes

        case .moveSetCursors(let cursors):
            var movements = Set<MovementID>()
            for (id, cursor) in cursors {
                guard let i = show.sets.firstIndex(where: { $0.id == id }) else { throw DrillError("Unknown set.") }
                show.sets[i].cursor = cursor
                movements.insert(show.sets[i].movementID)
            }
            for m in movements { try show.sortSets(in: m) }

        case .setPlacements(let setID, let placements):
            guard show.set(setID) != nil else { throw DrillError("Unknown set.") }
            var formation = show.formation(setID)
            var deltas: [PerformerID: Point2?] = [:]
            for (id, placement) in placements {
                guard show.performer(id) != nil else { throw DrillError("Unknown performer.") }
                if let old = formation[id].position, let new = placement.position {
                    deltas[id] = new.point - old.point
                } else {
                    deltas[id] = .some(nil)
                }
                formation[id] = placement
            }
            show.formations[setID] = formation
            show.reconcileForms(on: setID, deltas: deltas)

        case .applyForm(let form):
            guard show.set(form.setID) != nil else { throw DrillError("Unknown set.") }
            guard !form.members.isEmpty else { throw DrillError("Select performers before applying a form.") }
            guard show.form(form.id) == nil else { throw DrillError("Form already exists.") }
            let members = Set(form.members)
            for i in show.forms.indices where show.forms[i].setID == form.setID {
                show.forms[i].members.removeAll { members.contains($0) }
            }
            show.forms.removeAll { $0.members.isEmpty }
            show.forms.append(form)
            show.placeFormMembers(form)

        case .updateFormGeometry(let id, let geometry):
            guard let i = show.forms.firstIndex(where: { $0.id == id }) else { throw DrillError("Unknown form.") }
            show.forms[i].geometry = geometry
            show.placeFormMembers(show.forms[i])

        case .updateFormMembers(let id, let members):
            guard let i = show.forms.firstIndex(where: { $0.id == id }) else { throw DrillError("Unknown form.") }
            guard Set(members) == Set(show.forms[i].members) else { throw DrillError("Reordering cannot add or remove members.") }
            show.forms[i].members = members
            show.placeFormMembers(show.forms[i])

        case .detachForm(let id):
            guard show.form(id) != nil else { throw DrillError("Unknown form.") }
            show.forms.removeAll { $0.id == id }

        case .replaceTiming(let id, let track):
            guard let i = show.movements.firstIndex(where: { $0.id == id }) else { throw DrillError("Unknown movement.") }
            try track.validate()
            show.movements[i].timing = track

        case .setMovementAudio(let id, let asset):
            guard let i = show.movements.firstIndex(where: { $0.id == id }) else { throw DrillError("Unknown movement.") }
            show.movements[i].audioAssetID = asset

        case .addMediaAsset(let asset):
            guard !show.mediaAssets.contains(where: { $0.id == asset.id }) else { throw DrillError("Asset already exists.") }
            show.mediaAssets.append(asset)

        case .setAnalysisSettings(let settings):
            guard settings.maxStride > 0, settings.minClearance >= 0 else { throw DrillError("Thresholds must be positive.") }
            show.analysis = settings

        case .batch(_, let commands):
            guard !commands.isEmpty else { throw DrillError("Nothing to change.") }
            for command in commands { show = try command.applied(to: show) }
        }
        return show
    }
}

extension Show {
    /// Re-sorts a movement's sets by count position, keeping other movements in place.
    mutating func sortSets(in movementID: MovementID) throws {
        let map = try timingMap(for: movementID)
        var keyed: [(ArrivalSet, Rational)] = []
        for set in sets(in: movementID) {
            guard map.contains(set.cursor) else { throw DrillError("Set \(set.label) references a missing timing event.") }
            keyed.append((set, try map.pulse(at: set.cursor)))
        }
        keyed.sort { $0.1 < $1.1 }
        let sorted = keyed.map(\.0)
        var iterator = sorted.makeIterator()
        sets = sets.map { $0.movementID == movementID ? iterator.next()! : $0 }
        // The first set is the preset and never has an incoming move.
        if let first = sorted.first { transitions.removeAll { $0.toSetID == first.id } }
        for set in sorted.dropFirst() where transition(into: set.id) == nil {
            transitions.append(Transition(id: TransitionID(uuid: set.id.uuid), toSetID: set.id))
        }
    }

    mutating func placeFormMembers(_ form: Form) {
        var formation = self.formation(form.setID)
        for (id, point) in form.positions() {
            let facing = formation[id].position?.facing ?? 0
            let z = formation[id].position?.z ?? 0
            formation[id] = .placed(Position(x: point.x, y: point.y, z: z, facing: facing))
        }
        formations[form.setID] = formation
    }

    /// After direct placement edits: a uniform translation of every member moves
    /// the form; otherwise moved members leave their form (others keep positions).
    mutating func reconcileForms(on setID: SetID, deltas: [PerformerID: Point2?]) {
        for i in forms.indices where forms[i].setID == setID {
            let touched = forms[i].members.filter { deltas[$0] != nil }
            guard !touched.isEmpty else { continue }
            let moves = touched.compactMap { deltas[$0] ?? nil }
            if touched.count == forms[i].members.count, moves.count == touched.count,
               let first = moves.first, moves.allSatisfy({ $0.distance(to: first) < 1e-9 }) {
                forms[i].geometry = forms[i].geometry.translated(by: first)
            } else {
                let moved = Set(touched)
                forms[i].members.removeAll { moved.contains($0) }
            }
        }
        forms.removeAll { $0.members.isEmpty }
    }
}
