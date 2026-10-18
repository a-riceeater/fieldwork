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
        for form in forms {
            guard setIDs.contains(form.setID) else { throw DrillError("A form references a missing set.") }
            guard Set(form.members).count == form.members.count, form.members.allSatisfy(performerIDs.contains) else {
                throw DrillError("A form has invalid membership.")
            }
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
}
