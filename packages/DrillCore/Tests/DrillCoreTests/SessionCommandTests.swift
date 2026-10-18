import XCTest
import DrillTiming
@testable import DrillCore

final class SessionCommandTests: XCTestCase {
    func makeSession(performers: Int = 8) throws -> DocumentSession {
        let session = try DocumentSession(show: try Show.makeNew(title: "Test", measures: 8))
        try session.perform(try session.show.makeRoster([RosterSectionRequest(name: "Trumpet", prefix: "T", count: performers)]))
        return session
    }

    func testRosterCreatesStableLabelsAndExplicitUnresolvedState() throws {
        let session = try makeSession()
        XCTAssertEqual(session.show.performers.map(\.label), (1...8).map { "T\($0)" })
        let preset = session.show.sets[0].id
        XCTAssertEqual(session.show.formation(preset).placements.count, 8)
        XCTAssertTrue(session.show.formation(preset).placements.values.allSatisfy { $0 == .unresolved })
        // Adding to the same section continues numbering.
        try session.perform(try session.show.makeRoster([RosterSectionRequest(name: "Trumpet", prefix: "T", count: 2)]))
        XCTAssertEqual(session.show.sections.count, 1)
        XCTAssertEqual(session.show.performers.last?.label, "T10")
    }

    func testInstrumentPresetsHaveDistinctLettersAndIncludeGuard() {
        let prefixes = InstrumentPreset.all.map(\.prefix)
        XCTAssertEqual(Set(prefixes).count, prefixes.count)
        XCTAssertEqual(InstrumentPreset.named("flute")?.prefix, "F")
        XCTAssertEqual(InstrumentPreset.named(" Trumpet ")?.prefix, "T")
        XCTAssertEqual(InstrumentPreset.named("Color Guard")?.family, .colorGuard)
        XCTAssertNil(InstrumentPreset.named("Kazoo"))
        XCTAssertTrue(InstrumentPreset.Family.allCases.allSatisfy { !InstrumentPreset.family($0).isEmpty })
    }

    func testSectionLetterChangeRelabelsPerformersAndUndoes() throws {
        let session = try makeSession(performers: 3)
        let trumpets = try XCTUnwrap(session.show.sections.first)
        var custom = try XCTUnwrap(session.show.performers.last)
        custom.label = "Lead"
        try session.perform(.updatePerformer(custom))
        try session.perform(try session.show.makeRoster([RosterSectionRequest(name: "Tenor Saxophone", prefix: "N", count: 2)]))

        try session.perform(try session.show.makeSectionPrefix(trumpets.id, prefix: " TP "))
        XCTAssertEqual(session.show.section(trumpets.id)?.prefix, "TP")
        XCTAssertEqual(session.show.performers.map(\.label), ["TP1", "TP2", "Lead", "N1", "N2"])
        // Later additions continue with the new letter.
        try session.perform(try session.show.makeRoster([RosterSectionRequest(name: "Trumpet", prefix: "T", count: 1)]))
        XCTAssertEqual(session.show.performers.last?.label, "TP3")
        session.undo()
        session.undo()
        XCTAssertEqual(session.show.performers.map(\.label), ["T1", "T2", "Lead", "N1", "N2"])

        let saxes = try XCTUnwrap(session.show.sections.last)
        XCTAssertThrowsError(try session.show.makeSectionPrefix(saxes.id, prefix: "T"))
        XCTAssertThrowsError(try session.show.makeSectionPrefix(saxes.id, prefix: "  "))
        XCTAssertNoThrow(try session.show.makeSectionPrefix(saxes.id, prefix: "TS"))
    }

    func testRehearsalMarksMeasureMarkersAndCountingMode() throws {
        let session = try makeSession()
        let second = SetID()
        try session.perform(try session.show.makeCreateSet(after: session.show.sets[0].id, counts: 16, newSetID: second))
        let map = try TimingMap(track: session.show.movements[0].timing, assetID: nil)
        var set = try XCTUnwrap(session.show.set(second))
        XCTAssertEqual(session.show.measureLabel(for: set, map: map), try map.musicalPosition(at: set.cursor).label)
        XCTAssertEqual(session.show.cumulativeCount(of: set, map: map), Rational(16))

        try session.perform(.updateSetMarkers(second, rehearsalMark: " CC ", measureMarker: "222-223"))
        set = try XCTUnwrap(session.show.set(second))
        XCTAssertEqual(set.rehearsalMark, "CC")
        XCTAssertEqual(session.show.measureLabel(for: set, map: map), "m. 222-223")

        try session.perform(.setCountingMode(.counts))
        try session.perform(.updateSetMarkers(second, rehearsalMark: "CC", measureMarker: ""))
        set = try XCTUnwrap(session.show.set(second))
        XCTAssertEqual(session.show.measureLabel(for: set, map: map), "")
        session.undo()
        session.undo()
        XCTAssertEqual(session.show.countingMode, .measures)
        XCTAssertThrowsError(try session.perform(.updateSetMarkers(second, rehearsalMark: String(repeating: "A", count: 17), measureMarker: "")))

        // JSON written before these fields existed still decodes.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.show)) as! [String: Any]
        json["countingMode"] = nil
        json["sets"] = (json["sets"] as! [[String: Any]]).map { var s = $0; s["rehearsalMark"] = nil; s["measureMarker"] = nil; return s }
        let old = try JSONDecoder().decode(Show.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.countingMode, .measures)
        XCTAssertEqual(old.set(second)?.rehearsalMark, "")
    }

    func testQuickShapesPlaceTheSelectionInOneStep() throws {
        let session = try makeSession(performers: 12)
        let preset = session.show.sets[0].id
        let ids = session.show.performers.map(\.id)
        let spacing = 2 * session.show.field.stepSize

        func minimumGap() -> Double {
            let points = ids.compactMap { session.show.formation(preset)[$0].position?.point }
            XCTAssertEqual(points.count, ids.count, "everyone placed")
            var best = Double.infinity
            for i in points.indices { for j in points.indices where j > i { best = min(best, points[i].distance(to: points[j])) } }
            return best
        }

        for shape in QuickShape.allCases {
            try session.perform(try session.show.makeQuickShape(shape, members: ids, at: preset))
            XCTAssertEqual(session.undoName, "Place in \(shape.displayName)")
            XCTAssertGreaterThan(minimumGap(), spacing * 0.95, "\(shape) keeps neighbors apart")
            let retained = session.show.forms(on: preset).contains { Set($0.members) == Set(ids) }
            XCTAssertEqual(retained, shape == .line || shape == .arc, "\(shape) form retention")
        }
        // Lines are centered where the performers already were.
        try session.perform(try session.show.makeTranslate(ids, at: preset, by: Point2(5, 3)))
        let before = Rect2(points: ids.compactMap { session.show.formation(preset)[$0].position?.point }).center
        try session.perform(try session.show.makeQuickShape(.line, members: ids, at: preset))
        let after = Rect2(points: ids.compactMap { session.show.formation(preset)[$0].position?.point }).center
        XCTAssertLessThan(before.distance(to: after), 1e-6)
        XCTAssertThrowsError(try session.show.makeQuickShape(.block, members: [], at: preset))
    }

    func testPlaceUnplacedPutsEverySectionOnTheField() throws {
        let session = try DocumentSession(show: try Show.makeNew(title: "Band", measures: 8))
        try session.perform(try session.show.makeRoster([
            RosterSectionRequest(name: "Trumpet", prefix: "T", count: 16),
            RosterSectionRequest(name: "Mellophone", prefix: "M", count: 8),
            RosterSectionRequest(name: "Snare Drum", prefix: "S", count: 6),
            RosterSectionRequest(name: "Color Guard", prefix: "G", count: 40),
        ]))
        let preset = session.show.sets[0].id
        try session.perform(try session.show.makeSetCoordinate(session.show.performers[0].id, at: preset, x: 30, y: 10))
        try session.perform(try session.show.makePlaceUnplaced(at: preset))
        let formation = session.show.formation(preset)
        XCTAssertTrue(session.show.performers.allSatisfy { formation[$0.id].position != nil })
        XCTAssertEqual(formation[session.show.performers[0].id].position?.point, Point2(30, 10), "already placed performers stay put")
        let points = session.show.performers.dropFirst().compactMap { formation[$0.id].position?.point }
        let bounds = session.show.field.bounds
        XCTAssertTrue(points.allSatisfy { bounds.contains($0) }, "inside the field")
        var gap = Double.infinity
        for i in points.indices { for j in points.indices where j > i { gap = min(gap, points[i].distance(to: points[j])) } }
        XCTAssertGreaterThan(gap, 2 * session.show.field.stepSize * 0.95)
        XCTAssertThrowsError(try session.show.makePlaceUnplaced(at: preset), "nothing left to place")
        session.undo()
        XCTAssertEqual(session.show.formation(preset)[session.show.performers[1].id], .unresolved)
    }

    func testFormRetainsGeometryAndOrder() throws {
        let session = try makeSession()
        let preset = session.show.sets[0].id
        let ids = session.show.performers.map(\.id)
        try session.perform(try session.show.makeForm(.line(start: Point2(-7, 0), end: Point2(7, 0)), members: ids, at: preset))
        let form = try XCTUnwrap(session.show.forms.first)
        XCTAssertEqual(form.members, ids)
        XCTAssertEqual(session.show.formation(preset)[ids[0]].position?.x ?? .nan, -7, accuracy: 1e-9)
        XCTAssertEqual(session.show.formation(preset)[ids[7]].position?.x ?? .nan, 7, accuracy: 1e-9)

        // Editing geometry respaces the same members in the same order.
        try session.perform(.updateFormGeometry(form.id, .arc(start: Point2(-7, 0), end: Point2(7, 0), bulge: 3)))
        XCTAssertGreaterThan(session.show.formation(preset)[ids[3]].position!.y, 2)

        // Reversing assignment order mirrors positions.
        try session.perform(.updateFormMembers(form.id, ids.reversed()))
        XCTAssertEqual(session.show.formation(preset)[ids[0]].position?.x ?? .nan, 7, accuracy: 1e-9)

        // Translating every member moves the form; moving one member detaches only it.
        try session.perform(try session.show.makeTranslate(ids, at: preset, by: Point2(0, 2)))
        guard case .arc(let s, _, _) = session.show.forms[0].geometry else { return XCTFail() }
        XCTAssertEqual(s.y, 2, accuracy: 1e-9)
        try session.perform(try session.show.makeTranslate([ids[2]], at: preset, by: Point2(1, 0)))
        XCTAssertEqual(session.show.forms[0].members.count, 7)
        XCTAssertFalse(session.show.forms[0].members.contains(ids[2]))
    }

    func testCreateSetShiftsLaterSetsAndExtendsTimeline() throws {
        let session = try makeSession()
        let preset = session.show.sets[0].id
        try session.perform(try session.show.makeCreateSet(after: preset, counts: 16))
        let set2 = session.show.sets[1].id
        XCTAssertEqual(try session.show.moveCounts(into: set2), Rational(16))
        // Insert an 8-count set between preset and set 2: set 2 keeps its 16-count move.
        try session.perform(try session.show.makeCreateSet(after: preset, counts: 8))
        XCTAssertEqual(session.show.sets.map(\.label), ["1", "3", "2"])
        XCTAssertEqual(try session.show.moveCounts(into: set2), Rational(16))
        XCTAssertEqual(try session.show.timingMap(for: session.show.movements[0].id).pulse(at: session.show.set(set2)!.cursor), Rational(24))
        // A move beyond the 8-measure (32-count) timeline extends it in the same transaction.
        try session.perform(try session.show.makeCreateSet(after: set2, counts: 16))
        let map = try session.show.timingMap(for: session.show.movements[0].id)
        XCTAssertGreaterThanOrEqual(map.totalPulses, Rational(40))
        session.undo()
        XCTAssertEqual(session.show.movements[0].timing.measures.count, 8, "undo restores the timeline with the set")
    }

    func testCompoundUndoRedoRestoresEverythingTogether() throws {
        let session = try makeSession()
        let preset = session.show.sets[0].id
        let ids = session.show.performers.map(\.id)
        try session.perform(try session.show.makeForm(.line(start: Point2(-7, 0), end: Point2(7, 0)), members: ids, at: preset))
        try session.perform(try session.show.makeCreateSet(after: preset, counts: 16))
        let before = session.show
        try session.perform(try session.show.makeSetMoveCounts(session.show.sets[1].id, counts: 40))
        XCTAssertEqual(try session.show.moveCounts(into: session.show.sets[1].id), Rational(40))
        XCTAssertGreaterThan(session.show.movements[0].timing.measures.count, 8)
        XCTAssertEqual(session.undoName, "Change Move Counts")
        session.undo()
        XCTAssertEqual(session.show, before, "timeline, cursors and sets restored as one unit")
        session.redo()
        XCTAssertEqual(try session.show.moveCounts(into: session.show.sets[1].id), Rational(40))
    }

    func testInvalidCommandLeavesShowUntouched() throws {
        let session = try makeSession()
        let before = session.show
        let revision = session.revision
        XCTAssertThrowsError(try session.perform(.deleteSet(session.show.sets[0].id)))
        XCTAssertThrowsError(try session.perform(.batch("Bad", [.renameShow("Fine"), .renameShow("  ")])))
        XCTAssertEqual(session.show, before)
        XCTAssertEqual(session.revision, revision)
        XCTAssertFalse(session.canRedo)
    }

    func testDirtyStateFollowsUndoToSavedState() throws {
        let session = try makeSession()
        session.markSaved()
        XCTAssertFalse(session.isDirty)
        try session.perform(.renameShow("Renamed"))
        XCTAssertTrue(session.isDirty)
        session.undo()
        XCTAssertFalse(session.isDirty)
        session.redo()
        XCTAssertTrue(session.isDirty)

        // A background save captures a state; edits made meanwhile stay unsaved.
        let captured = session.currentStateID
        try session.perform(.renameShow("Edited During Save"))
        session.markSaved(state: captured)
        XCTAssertTrue(session.isDirty)
        session.undo()
        XCTAssertFalse(session.isDirty)
    }

    func testExactCoordinateAndNudge() throws {
        let session = try makeSession(performers: 2)
        let preset = session.show.sets[0].id
        let id = session.show.performers[0].id
        try session.perform(try session.show.makeSetCoordinate(id, at: preset, x: 3.5, y: -2))
        try session.perform(try session.show.makeTranslate([id], at: preset, by: Point2(session.show.field.stepSize, 0)))
        XCTAssertEqual(session.show.formation(preset)[id].position?.x ?? .nan, 3.5 + session.show.field.stepSize, accuracy: 1e-12)
        // Unplaced performers are not silently placed at the origin by a nudge.
        XCTAssertThrowsError(try session.show.makeTranslate([session.show.performers[1].id], at: preset, by: Point2(1, 0)))
    }

    func testCommandsRoundTripThroughJSONForJournalReplay() throws {
        let session = try makeSession()
        let baseline = session.show
        var events: [CommitEvent] = []
        session.observe { events.append($0) }
        let preset = session.show.sets[0].id
        let ids = session.show.performers.map(\.id)
        try session.perform(try session.show.makeForm(.arc(start: Point2(-5, 0), end: Point2(5, 0), bulge: 2), members: ids, at: preset))
        try session.perform(try session.show.makeCreateSet(after: preset, counts: 12))
        session.undo()
        session.redo()
        try session.perform(try session.show.makeTranslate(ids, at: session.show.sets[1].id, by: Point2(0, 4)))

        let data = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([CommitEvent].self, from: data)
        let fresh = try DocumentSession(show: baseline)
        for event in decoded { try fresh.replay(event) }
        XCTAssertEqual(fresh.show, session.show)
    }
}
