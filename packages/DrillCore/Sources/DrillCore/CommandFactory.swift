import Foundation
import DrillTiming

/// One section to create in a roster setup.
public struct RosterSectionRequest: Hashable, Sendable {
    public var name: String
    public var prefix: String
    public var count: Int
    public var symbol: PerformerSymbol
    public var colorIndex: Int

    public init(name: String, prefix: String, count: Int, symbol: PerformerSymbol = .circle, colorIndex: Int = 0) {
        self.name = name
        self.prefix = prefix
        self.count = count
        self.symbol = symbol
        self.colorIndex = colorIndex
    }
}

/// Builders that turn user intents into fully resolved commands (all IDs and
/// derived values generated up front). They read the current show but never mutate it.
extension Show {
    /// Creates sections and their performers. New performers are explicitly
    /// unresolved at every existing set.
    public func makeRoster(_ requests: [RosterSectionRequest]) throws -> DrillCommand {
        var commands: [DrillCommand] = []
        var performers: [Performer] = []
        var usedLabels = Set(self.performers.map(\.label))
        for request in requests {
            guard request.count >= 0, request.count <= 1000 else { throw DrillError("Section size must be between 0 and 1000.") }
            let existing = sections.first { $0.name.caseInsensitiveCompare(request.name) == .orderedSame }
            let section = existing ?? Section(name: request.name, prefix: request.prefix, symbol: request.symbol, colorIndex: request.colorIndex)
            if existing == nil { commands.append(.addSection(section)) }
            var n = 1
            for _ in 0..<request.count {
                while usedLabels.contains("\(section.prefix)\(n)") { n += 1 }
                let label = "\(section.prefix)\(n)"
                usedLabels.insert(label)
                performers.append(Performer(label: label, sectionID: section.id))
            }
        }
        if !performers.isEmpty {
            var placements: [SetID: [PerformerID: Placement]] = [:]
            for set in sets { placements[set.id] = Dictionary(uniqueKeysWithValues: performers.map { ($0.id, Placement.unresolved) }) }
            commands.append(.addPerformers(performers, placements: placements))
        }
        guard !commands.isEmpty else { throw DrillError("Nothing to add.") }
        return commands.count == 1 ? commands[0] : .batch(performers.count == 1 ? "Add Performer" : "Add \(performers.count) Performers", commands)
    }

    /// Changes a section's label letter and relabels its performers that use it
    /// (T3 → TS3) as one undoable edit. Labels changed by hand are kept.
    public func makeSectionPrefix(_ id: SectionID, prefix: String) throws -> DrillCommand {
        let prefix = prefix.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { throw DrillError("A section needs a label letter.") }
        guard var section = section(id) else { throw DrillError("That section no longer exists.") }
        guard section.prefix != prefix else { throw DrillError("Nothing to change.") }
        let old = section.prefix
        section.prefix = prefix
        var relabeled: [Performer] = []
        for var performer in performers(in: id) {
            let number = performer.label.dropFirst(old.count)
            guard performer.label.hasPrefix(old), !number.isEmpty, number.allSatisfy(\.isNumber) else { continue }
            performer.label = prefix + number
            relabeled.append(performer)
        }
        let renamedIDs = Set(relabeled.map(\.id))
        let kept = Set(performers.filter { !renamedIDs.contains($0.id) }.map(\.label))
        if let clash = relabeled.first(where: { kept.contains($0.label) }) {
            throw DrillError("\(clash.label) is already used by another performer. Choose a different letter.")
        }
        return .batch("Change Section Letter", [.updateSection(section)] + relabeled.map { .updatePerformer($0) })
    }

    /// Timeline extension (as a replaced track) so that `pulse` exists, or nil if it already does.
    func extendedTiming(_ movement: Movement, toInclude pulse: Rational) throws -> TimingTrack? {
        var track = movement.timing
        var map = try TimingMap(track: track, assetID: nil)
        guard pulse > map.totalPulses else { return nil }
        guard let lastMeasure = track.measures.last,
              let lastBeat = track.events.last(where: { $0.kind == .beat }),
              let bpm = track.baselineTempo(of: lastBeat) else { throw DrillError("The timeline cannot be extended.") }
        let meter = Meter(lastMeasure.meter.numerator, lastMeasure.meter.denominator, grouping: lastMeasure.meter.grouping)
        while pulse > map.totalPulses {
            try track.appendMeasures(4, meter: meter, bpm: min(max(bpm, 10), 500), tempoUnit: lastMeasure.tempoUnit, pulseUnit: lastMeasure.pulseUnit)
            map = try TimingMap(track: track, assetID: nil)
        }
        return track
    }

    /// Adds a set arriving `counts` after `previous`. Later sets shift by the same
    /// number of counts so their own moves keep their lengths. The formation copies
    /// the previous set (the common "duplicate and move" workflow) or starts unresolved.
    public func makeCreateSet(after previousID: SetID, counts: Int, label: String? = nil, copyPositions: Bool = true,
                              newSetID: SetID = SetID()) throws -> DrillCommand {
        guard counts > 0, counts <= 4096 else { throw DrillError("A move needs between 1 and 4096 counts.") }
        guard let previous = set(previousID), let movement = movement(previous.movementID) else { throw DrillError("Unknown set.") }
        var commands: [DrillCommand] = []
        let map0 = try TimingMap(track: movement.timing, assetID: nil)
        let startPulse = try map0.pulse(at: previous.cursor)
        let later = try sets(in: movement.id).filter { try map0.pulse(at: $0.cursor) > startPulse }
        let lastPulse = try later.last.map { try map0.pulse(at: $0.cursor) } ?? startPulse
        var track = movement.timing
        if let extended = try extendedTiming(movement, toInclude: max(startPulse + Rational(counts), lastPulse + (later.isEmpty ? .zero : Rational(counts)))) {
            track = extended
            commands.append(.replaceTiming(movement.id, extended))
        }
        let map = try TimingMap(track: track, assetID: nil)
        if !later.isEmpty {
            var cursors: [SetID: TimelineCursor] = [:]
            for set in later { cursors[set.id] = try map.cursor(atPulse: try map.pulse(at: set.cursor) + Rational(counts)) }
            commands.append(.moveSetCursors(cursors))
        }
        let cursor = try map.cursor(atPulse: startPulse + Rational(counts))
        let newLabel = label ?? nextSetLabel(in: movement.id)
        let arrival = ArrivalSet(id: newSetID, movementID: movement.id, label: newLabel, cursor: cursor)
        var formation = Formation()
        for performer in performers {
            formation[performer.id] = copyPositions ? self.formation(previousID)[performer.id] : .unresolved
        }
        commands.append(.createSet(arrival, transition: Transition(toSetID: arrival.id), formation: formation))
        return commands.count == 1 ? commands[0] : .batch("Add Set", commands)
    }

    public func nextSetLabel(in movementID: MovementID) -> String {
        let used = Set(sets(in: movementID).map(\.label))
        var n = sets(in: movementID).count + 1
        while used.contains(String(n)) { n += 1 }
        return String(n)
    }

    /// Changes the counts of the move into a set; later sets shift by the difference.
    public func makeSetMoveCounts(_ setID: SetID, counts: Int) throws -> DrillCommand {
        guard counts > 0, counts <= 4096 else { throw DrillError("A move needs between 1 and 4096 counts.") }
        guard let set = set(setID), let previous = previousSet(before: setID), let movement = movement(set.movementID) else {
            throw DrillError("The preset has no incoming move.")
        }
        let map0 = try TimingMap(track: movement.timing, assetID: nil)
        let oldPulse = try map0.pulse(at: set.cursor)
        let delta = try map0.pulse(at: previous.cursor) + Rational(counts) - oldPulse
        guard !delta.isZero else { throw DrillError("The move already has \(counts) counts.") }
        let affected = try sets(in: movement.id).filter { try map0.pulse(at: $0.cursor) >= oldPulse }
        let maxPulse = try affected.map { try map0.pulse(at: $0.cursor) }.max() ?? oldPulse
        var commands: [DrillCommand] = []
        var track = movement.timing
        if let extended = try extendedTiming(movement, toInclude: maxPulse + delta) {
            track = extended
            commands.append(.replaceTiming(movement.id, extended))
        }
        let map = try TimingMap(track: track, assetID: nil)
        var cursors: [SetID: TimelineCursor] = [:]
        for s in affected { cursors[s.id] = try map.cursor(atPulse: try map.pulse(at: s.cursor) + delta) }
        commands.append(.moveSetCursors(cursors))
        return commands.count == 1 ? commands[0] : .batch("Change Move Counts", commands)
    }

    /// Splits the move into a set with a subset that arrives `count` counts into it
    /// (1 → 2 becomes 1 → 1A → 2). The subset's formation is where everyone is at
    /// that count of the straight move, so playback is unchanged. Timing and
    /// later sets stay where they are.
    public func makeSplitMove(into setID: SetID, atCount count: Rational, label: String? = nil,
                              newSetID: SetID = SetID()) throws -> DrillCommand {
        guard let set = set(setID), let previous = previousSet(before: setID) else {
            throw DrillError("The preset has no incoming move to split.")
        }
        let map = try timingMap(for: set.movementID)
        let startPulse = try map.pulse(at: previous.cursor)
        let total = try map.pulse(at: set.cursor) - startPulse
        guard Rational.zero < count, count < total else {
            throw DrillError("Split the move somewhere between count 0 and count \(total).")
        }
        let pulse = startPulse + count
        let evaluated = try SceneEvaluator(show: self, movementID: set.movementID, map: map).evaluate(pulse: pulse.doubleValue)
        var formation = Formation()
        for performer in evaluated.performers {
            switch performer.state {
            case .placed: formation[performer.id] = .placed(Position(x: performer.x, y: performer.y, z: performer.z, facing: performer.facing))
            case .unresolved: formation[performer.id] = .unresolved
            case .inactive: formation[performer.id] = .inactive
            }
        }
        let subset = ArrivalSet(id: newSetID, movementID: set.movementID, label: label ?? subsetLabel(after: previous),
                                cursor: try map.cursor(atPulse: pulse), isSubset: true)
        return .batch("Split Move", [.createSet(subset, transition: Transition(toSetID: subset.id), formation: formation)])
    }

    /// The first free lettered label after a set: "1" gives "1A", then "1B";
    /// a subset such as "1A" gives "1B".
    public func subsetLabel(after previous: ArrivalSet) -> String {
        var root = previous.label
        if previous.isSubset {
            let stripped = String(root.reversed().drop(while: \.isLetter).reversed())
            if !stripped.isEmpty { root = stripped }
        }
        let used = Set(sets(in: previous.movementID).map(\.label))
        for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" where !used.contains(root + String(letter)) {
            return root + String(letter)
        }
        return nextSetLabel(in: previous.movementID)
    }

    /// Moves performers by a world offset at one set (arrow-key nudge or drag commit).
    public func makeTranslate(_ ids: [PerformerID], at setID: SetID, by delta: Point2) throws -> DrillCommand {
        var placements: [PerformerID: Placement] = [:]
        for id in ids {
            guard case .placed(var p) = formation(setID)[id] else { continue }
            p.point = p.point + delta
            placements[id] = .placed(p)
        }
        guard !placements.isEmpty else { throw DrillError("Only placed performers can be moved.") }
        return .setPlacements(setID, placements)
    }

    /// Sets one performer's exact coordinates (inspector entry).
    public func makeSetCoordinate(_ id: PerformerID, at setID: SetID, x: Double, y: Double) throws -> DrillCommand {
        guard x.isFinite, y.isFinite else { throw DrillError("Coordinates must be numbers.") }
        var p = formation(setID)[id].position ?? Position(x: x, y: y)
        p.x = x
        p.y = y
        return .setPlacements(setID, [id: .placed(p)])
    }

    /// Applies a line or arc to performers in the given order.
    public func makeForm(_ geometry: FormGeometry, members: [PerformerID], at setID: SetID, formID: FormID = FormID()) throws -> DrillCommand {
        guard !members.isEmpty else { throw DrillError("Select performers before applying a form.") }
        guard geometry.length > 1e-6 || members.count == 1 else { throw DrillError("Drag to give the form a length.") }
        return .applyForm(Form(id: formID, setID: setID, geometry: geometry, members: members))
    }

    /// Performers ordered for assignment along a new form: by drill label within section order.
    public func sequentialOrder(_ ids: [PerformerID]) -> [PerformerID] {
        let sectionOrder = Dictionary(uniqueKeysWithValues: sections.enumerated().map { ($1.id, $0) })
        let index = Dictionary(uniqueKeysWithValues: performers.enumerated().map { ($1.id, $0) })
        return ids.sorted {
            let a = performer($0)!, b = performer($1)!
            if a.sectionID != b.sectionID { return sectionOrder[a.sectionID, default: 0] < sectionOrder[b.sectionID, default: 0] }
            return index[$0, default: 0] < index[$1, default: 0]
        }
    }

    /// Embeds an audio asset and selects it as the movement's clock.
    public func makeImportAudio(_ asset: MediaAssetInfo, movementID: MovementID) throws -> DrillCommand {
        guard movement(movementID) != nil else { throw DrillError("Unknown movement.") }
        guard asset.sampleRate > 0, asset.frameCount > 0 else { throw DrillError("The audio file has no decodable samples.") }
        var commands: [DrillCommand] = []
        if !mediaAssets.contains(where: { $0.id == asset.id }) { commands.append(.addMediaAsset(asset)) }
        commands.append(.setMovementAudio(movementID, asset.id))
        return .batch("Import Audio", commands)
    }

    /// "Align measure/beat here": pins a musical cursor to the playhead's sample frame.
    public func makeAlignHere(movementID: MovementID, cursor: TimelineCursor, sampleFrame: Int64,
                              resolution: TimingResolution? = nil, anchorID: AnchorID = AnchorID()) throws -> (command: DrillCommand, report: FitReport) {
        guard let movement = movement(movementID) else { throw DrillError("Unknown movement.") }
        guard let assetID = movement.audioAssetID, let asset = mediaAssets.first(where: { $0.id == assetID }) else {
            throw DrillError("Import audio before aligning music.")
        }
        guard sampleFrame >= 0, sampleFrame <= asset.frameCount else { throw DrillError("The playhead is outside the audio file.") }
        let anchor = AudioAnchor(id: anchorID, cursor: cursor, assetID: assetID, sampleFrame: sampleFrame, sampleRate: asset.sampleRate)
        let outcome = try TimingEditor.addAnchor(anchor, to: movement.timing, resolution: resolution)
        return (.batch("Align Here", [.replaceTiming(movementID, outcome.track)]), outcome.report)
    }

    /// "Align selected set arrival here": the same anchor, at the set's musical position.
    public func makeAlignSetArrival(_ setID: SetID, sampleFrame: Int64, resolution: TimingResolution? = nil,
                                    anchorID: AnchorID = AnchorID()) throws -> (command: DrillCommand, report: FitReport) {
        guard let set = set(setID) else { throw DrillError("Unknown set.") }
        let result = try makeAlignHere(movementID: set.movementID, cursor: set.cursor, sampleFrame: sampleFrame, resolution: resolution, anchorID: anchorID)
        return (.batch("Align Set \(set.label) Arrival", [result.command]), result.report)
    }

    public func makeMoveAnchor(movementID: MovementID, anchorID: AnchorID, sampleFrame: Int64) throws -> (command: DrillCommand, report: FitReport) {
        guard let movement = movement(movementID) else { throw DrillError("Unknown movement.") }
        let outcome = try TimingEditor.moveAnchor(anchorID, toSampleFrame: sampleFrame, in: movement.timing)
        return (.batch("Move Anchor", [.replaceTiming(movementID, outcome.track)]), outcome.report)
    }

    public func makeRemoveAnchor(movementID: MovementID, anchorID: AnchorID) throws -> DrillCommand {
        guard let movement = movement(movementID) else { throw DrillError("Unknown movement.") }
        let outcome = try TimingEditor.removeAnchor(anchorID, from: movement.timing)
        return .batch("Remove Anchor", [.replaceTiming(movementID, outcome.track)])
    }

    /// Changes the notated tempo of a measure range, honoring the movement's fit mode.
    public func makeTempo(movementID: MovementID, measures: ClosedRange<Int>, bpm: Double,
                          resolution: TimingResolution? = nil) throws -> (command: DrillCommand, report: FitReport) {
        guard let movement = movement(movementID) else { throw DrillError("Unknown movement.") }
        let outcome = try TimingEditor.setTempo(measures: measures, bpm: bpm, in: movement.timing, assetID: movement.audioAssetID, resolution: resolution)
        return (.batch("Change Tempo", [.replaceTiming(movementID, outcome.track)]), outcome.report)
    }

    /// Replaces the timeline of a movement that has no sets or anchors beyond the preset
    /// (initial meter/tempo setup). Structural edits of referenced music need an impact plan.
    public func makeConfigureTimeline(movementID: MovementID, meter: Meter, bpm: Double, tempoUnit: Rational? = nil,
                                      pulseUnit: Rational? = nil, measures: Int, pickupBeats: Int = 0) throws -> DrillCommand {
        guard let movement = movement(movementID) else { throw DrillError("Unknown movement.") }
        let movementSets = sets(in: movementID)
        guard movementSets.count == 1, movement.timing.anchors.isEmpty else {
            throw DrillError("Meter and pulse can only be reset before sets or audio anchors exist. Use tempo edits instead.")
        }
        let track = try TimingTrack.make(meter: meter, bpm: bpm, tempoUnit: tempoUnit, pulseUnit: pulseUnit, measures: measures, pickupBeats: pickupBeats)
        var cursors: [SetID: TimelineCursor] = [:]
        cursors[movementSets[0].id] = TimelineCursor(eventID: track.events[0].id)
        return .batch("Set Meter and Tempo", [.replaceTiming(movementID, TimingTrack(measures: track.measures, events: track.events, anchors: [], fitMode: movement.timing.fitMode)),
                                              .moveSetCursors(cursors)])
    }
}
