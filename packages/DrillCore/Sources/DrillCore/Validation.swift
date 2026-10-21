import Foundation
import DrillTiming

extension Show {
    /// Checks model invariants. Every command result must pass before it commits.
    public func validate() throws {
        try field.validate()
        guard !movements.isEmpty else { throw DrillError("A show needs at least one movement.") }
        let sectionIDs = Set(sections.map(\.id))
        guard sectionIDs.count == sections.count else { throw DrillError("Duplicate section IDs.") }
        let performerIDs = Set(performers.map(\.id))
        guard performerIDs.count == performers.count else { throw DrillError("Duplicate performer IDs.") }
        for performer in performers where !sectionIDs.contains(performer.sectionID) {
            throw DrillError("Performer \(performer.label) belongs to a missing section.")
        }
        let labels = performers.map(\.label)
        guard Set(labels).count == labels.count else { throw DrillError("Performer labels must be unique.") }

        let assetIDs = Set(mediaAssets.map(\.id))
        let setIDs = Set(sets.map(\.id))
        guard setIDs.count == sets.count else { throw DrillError("Duplicate set IDs.") }
        // Arrival pulse of every set and the set each move starts from, for path checks.
        var pulseOf: [SetID: Rational] = [:]
        var previousOf: [SetID: SetID] = [:]
        for movement in movements {
            if let audio = movement.audioAssetID, !assetIDs.contains(audio) {
                throw DrillError("\(movement.name) references missing audio.")
            }
            let map: TimingMap
            do { map = try TimingMap(track: movement.timing, assetID: movement.audioAssetID) } catch {
                throw DrillError("\(movement.name) timing is invalid: \(error)")
            }
            let movementSets = sets(in: movement.id)
            guard !movementSets.isEmpty else { throw DrillError("\(movement.name) needs a preset.") }
            var previous: Rational?
            for (i, set) in movementSets.enumerated() {
                guard map.contains(set.cursor) else { throw DrillError("Set \(set.label) references a missing timing event.") }
                let pulse = try map.pulse(at: set.cursor)
                if let previous, pulse <= previous {
                    throw DrillError("Set \(set.label) must arrive after the previous set.")
                }
                if i == 0 {
                    guard transition(into: set.id) == nil else { throw DrillError("The preset cannot have an incoming move.") }
                } else {
                    guard transition(into: set.id) != nil else { throw DrillError("Set \(set.label) is missing its incoming move.") }
                }
                previous = pulse
                pulseOf[set.id] = pulse
                if i > 0 { previousOf[set.id] = movementSets[i - 1].id }
            }
        }
        for key in formations.keys where !setIDs.contains(key) { throw DrillError("A formation references a missing set.") }
        for (_, formation) in formations {
            for key in formation.placements.keys where !performerIDs.contains(key) {
                throw DrillError("A formation references a missing performer.")
            }
            for case .placed(let p) in formation.placements.values where !(p.x.isFinite && p.y.isFinite && p.z.isFinite && p.facing.isFinite) {
                throw DrillError("Positions must be finite numbers.")
            }
        }
        let transitionTargets = transitions.map(\.toSetID)
        guard Set(transitionTargets).count == transitionTargets.count else { throw DrillError("A set has more than one incoming move.") }
        for t in transitions where !setIDs.contains(t.toSetID) { throw DrillError("A move references a missing set.") }
        for t in transitions where !t.paths.isEmpty {
            guard let from = previousOf[t.toSetID], let end = pulseOf[t.toSetID], let begin = pulseOf[from] else {
                throw DrillError("The preset cannot have paths.")
            }
            try validatePaths(t, from: from, counts: end - begin, performerIDs: performerIDs)
        }
        for form in forms {
            if case .curve(let points) = form.geometry { try DrawnShape.curve(points: points).validate() }
            if case .circle(let center, let radius) = form.geometry {
                guard center.x.isFinite, center.y.isFinite, radius.isFinite, radius > 0 else {
                    throw DrillError("Circles must have a finite center and a positive radius.")
                }
            }
            guard setIDs.contains(form.setID) else { throw DrillError("A form references a missing set.") }
            guard Set(form.members).count == form.members.count, form.members.allSatisfy(performerIDs.contains) else {
                throw DrillError("A form has invalid membership.")
            }
        }
        let noteIDs = Set(fieldNotes.map(\.id))
        guard noteIDs.count == fieldNotes.count else { throw DrillError("Duplicate note IDs.") }
        for note in fieldNotes {
            guard setIDs.contains(note.setID) else { throw DrillError("A note references a missing set.") }
            guard note.position.x.isFinite, note.position.y.isFinite else { throw DrillError("Note positions must be finite numbers.") }
            guard note.text.count <= FieldNote.maxLength else { throw DrillError("Notes are limited to \(FieldNote.maxLength) characters.") }
        }
        // A performer belongs to at most one form per set.
        var membership = Set<String>()
        for form in forms {
            for member in form.members {
                guard membership.insert("\(form.setID)|\(member)").inserted else {
                    throw DrillError("A performer is in two forms on the same set.")
                }
            }
        }
    }

    /// The path invariants of one move (schema doc §7).
    func validatePaths(_ t: Transition, from: SetID, counts: Rational, performerIDs: Set<PerformerID>) throws {
        let label = set(t.toSetID)?.label ?? "?"
        for (id, path) in t.paths {
            guard performerIDs.contains(id) else { throw DrillError("A path in the move to set \(label) references a missing performer.") }
            let who = performer(id)?.label ?? "?"
            guard case .placed(let a) = formation(from)[id], case .placed(let b) = formation(t.toSetID)[id] else {
                throw DrillError("\(who) has a path into set \(label) but is not placed at both ends of the move.")
            }
            guard !path.segments.isEmpty else { throw DrillError("\(who)'s path into set \(label) has no segments.") }
            var point = a.point
            for segment in path.segments {
                guard segment.counts > .zero else { throw DrillError("\(who)'s path into set \(label) has a segment without counts.") }
                switch segment {
                case .hold: break
                case .line(_, let to):
                    guard to.x.isFinite, to.y.isFinite else { throw DrillError("Path points must be finite numbers.") }
                    point = to
                case .arc(_, let to, let sweep):
                    guard to.x.isFinite, to.y.isFinite else { throw DrillError("Path points must be finite numbers.") }
                    guard sweep.isFinite, sweep != 0, abs(sweep) < 360 else {
                        throw DrillError("\(who)'s path into set \(label) has an arc that does not turn between 0 and 360 degrees.")
                    }
                    guard point.distance(to: to) > PerformerPath.minimumChord else {
                        throw DrillError("\(who)'s path into set \(label) has an arc without a chord.")
                    }
                    point = to
                }
            }
            guard path.totalCounts == counts else {
                throw DrillError("\(who)'s path into set \(label) lasts \(path.totalCounts) counts, but the move has \(counts).")
            }
            guard point.distance(to: b.point) <= 1e-6 else { throw DrillError("\(who)'s path into set \(label) does not end at the set's position.") }
        }
    }
}
