import Foundation
import DrillTiming

/// Small original demo show used by the tutorial and as a fixture. Every step
/// goes through the same commands a user would issue.
public enum SampleShow {
    public static func make(title: String = "Sample: First Light") throws -> Show {
        let session = try DocumentSession(show: try Show.makeNew(title: title, measures: 24))
        try session.perform(try session.show.makeRoster([
            RosterSectionRequest(name: "Trumpet", prefix: "T", count: 6, symbol: .circle, colorIndex: 0),
            RosterSectionRequest(name: "Mellophone", prefix: "M", count: 4, symbol: .triangle, colorIndex: 1),
            RosterSectionRequest(name: "Low Brass", prefix: "B", count: 4, symbol: .square, colorIndex: 2),
            RosterSectionRequest(name: "Battery", prefix: "D", count: 4, symbol: .cross, colorIndex: 3),
        ]))
        let step = session.show.field.stepSize
        let preset = session.show.sets[0].id

        // Preset: a block centered between the 45s, two steps apart, four deep.
        var placements: [PerformerID: Placement] = [:]
        for (i, performer) in session.show.performers.enumerated() {
            let column = Double(i % 6) - 2.5, row = Double(i / 6)
            placements[performer.id] = .placed(Position(x: column * 2 * step, y: -8 * step + row * 2 * step))
        }
        try session.perform(.setPlacements(preset, placements))

        // Set 2: 16 counts later, a company front on the front hash.
        try session.perform(try session.show.makeCreateSet(after: preset, counts: 16))
        let set2 = session.show.sets[1].id
        let all = session.show.sequentialOrder(session.show.performers.map(\.id))
        let frontHash = session.show.field.checkpoints.first { $0.label == "front hash" }!.position
        try session.perform(try session.show.makeForm(.line(start: Point2(-17 * 2 * step / 2, frontHash), end: Point2(17 * 2 * step / 2, frontHash)),
                                                      members: all, at: set2))

        // Set 3: 16 counts later, an arc opening toward the audience.
        try session.perform(try session.show.makeCreateSet(after: set2, counts: 16))
        let set3 = session.show.sets[2].id
        try session.perform(try session.show.makeForm(.arc(start: Point2(-16 * step, frontHash + 4 * step), end: Point2(16 * step, frontHash + 4 * step), bulge: 8 * step),
                                                      members: all, at: set3))

        // Set 4: 8 counts later, the arc slides two steps toward the back sideline.
        try session.perform(try session.show.makeCreateSet(after: set3, counts: 8))
        let set4 = session.show.sets[3].id
        try session.perform(try session.show.makeTranslate(all, at: set4, by: Point2(0, 2 * step)))
        return session.show
    }

    /// A large fixture for profiling: `performers` dots across `sets` arrivals.
    public static func makeLarge(performers count: Int = 350, sets setCount: Int = 150, countsPerMove: Int = 8) throws -> Show {
        var show = try Show.makeNew(title: "Profile \(count)×\(setCount)", measures: max(4, setCount * countsPerMove / 4 + 4))
        let sectionCount = 10
        let sectionSize = Int((Double(count) / Double(sectionCount)).rounded(.up))
        var requests: [RosterSectionRequest] = []
        var remaining = count
        for s in 0..<sectionCount where remaining > 0 {
            let n = min(sectionSize, remaining)
            requests.append(RosterSectionRequest(name: "Section \(s + 1)", prefix: String(UnicodeScalar(UInt8(65 + s))), count: n, colorIndex: s))
            remaining -= n
        }
        show = try show.makeRoster(requests).applied(to: show)
        let map = try show.timingMap(for: show.movements[0].id)
        let step = show.field.stepSize
        let movementID = show.movements[0].id
        var sets = [show.sets[0]]
        for k in 1..<setCount {
            let set = ArrivalSet(movementID: movementID, label: String(k + 1), cursor: try map.cursor(atCount: k * countsPerMove))
            sets.append(set)
            show.transitions.append(Transition(toSetID: set.id))
        }
        show.sets = sets
        for (k, set) in sets.enumerated() {
            var formation = Formation()
            let phase = Double(k) * 0.35
            for (i, performer) in show.performers.enumerated() {
                let column = Double(i % 25) - 12, row = Double(i / 25) - 7
                let x = column * 2 * step + sin(phase + row * 0.3) * 4 * step
                let y = row * 2 * step + cos(phase + column * 0.2) * 3 * step
                formation[performer.id] = .placed(Position(x: x, y: y))
            }
            show.formations[set.id] = formation
        }
        try show.validate()
        return show
    }
}
