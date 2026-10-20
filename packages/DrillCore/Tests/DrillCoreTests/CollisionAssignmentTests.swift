import XCTest
import DrillTiming
@testable import DrillCore

final class CollisionAssignmentTests: XCTestCase {
    private func fixture(_ points: [Point2]) throws -> (DocumentSession, [PerformerID], SetID, SetID) {
        let session = try DocumentSession(show: Show.makeNew(title: "Collision assignment", measures: 8))
        try session.perform(try session.show.makeRoster([RosterSectionRequest(name: "Trumpet", prefix: "T", count: points.count)]))
        let ids = session.show.performers.map(\.id), preset = session.show.sets[0].id
        try place(points, ids: ids, at: preset, in: session)
        try session.perform(try session.show.makeCreateSet(after: preset, counts: 8))
        return (session, ids, preset, try XCTUnwrap(session.show.nextSet(after: preset)).id)
    }

    private func place(_ points: [Point2], ids: [PerformerID], at set: SetID, in session: DocumentSession) throws {
        try session.perform(.setPlacements(set, Dictionary(uniqueKeysWithValues: zip(ids, points).map {
            ($0, Placement.placed(Position(x: $1.x, y: $1.y)))
        })))
    }

    private func closePasses(_ session: DocumentSession) throws -> [DrillIssue] {
        try DrillAnalyzer.analyze(session.show, movementID: session.show.movements[0].id).filter { $0.kind == .closePass }
    }

    func testIncomingCollisionOverridesNearestCurrentDotsAndUndoes() throws {
        let (session, ids, _, arrival) = try fixture([Point2(-2, 0), Point2(2, 0)])
        try place([Point2(2, 0), Point2(-2, 0)], ids: ids, at: arrival, in: session)
        XCTAssertEqual(try closePasses(session).count, 1)
        let before = session.show
        try session.perform(try session.show.makeForm(.line(start: Point2(-2, 0), end: Point2(2, 0)), members: ids, at: arrival))
        XCTAssertTrue(try closePasses(session).isEmpty)
        XCTAssertEqual(session.show.forms.last?.members, ids)
        let after = session.show
        session.undo()
        XCTAssertEqual(session.show, before)
        session.redo()
        XCTAssertEqual(session.show, after)
    }

    func testEditingPresetConsidersOutgoingMove() throws {
        let (session, ids, preset, arrival) = try fixture([Point2(-2, 0), Point2(2, 0)])
        try place([Point2(2, 0), Point2(-2, 0)], ids: ids, at: arrival, in: session)
        try session.perform(try session.show.makeForm(.line(start: Point2(-2, 0), end: Point2(2, 0)), members: ids, at: preset))
        XCTAssertTrue(try closePasses(session).isEmpty)
        XCTAssertEqual(session.show.forms.last?.members, Array(ids.reversed()))
    }

    func testUnselectedStationaryPerformerAffectsAssignment() throws {
        let (session, ids, _, arrival) = try fixture([Point2(-3, 1), Point2(-2, 3), .zero])
        let targets = [Point2(2, -1), Point2(2, 2)]
        try place(targets, ids: Array(ids.prefix(2)), at: arrival, in: session)
        XCTAssertFalse(try closePasses(session).isEmpty)
        try session.perform(try session.show.makeForm(.line(start: targets[0], end: targets[1]), members: Array(ids.prefix(2)), at: arrival))
        XCTAssertTrue(try closePasses(session).isEmpty)
        XCTAssertEqual(session.show.formation(arrival)[ids[2]].position?.point, .zero)
        XCTAssertEqual(session.show.forms.last?.members, Array(ids.prefix(2).reversed()))
    }

    func testHoldsKeepCrossingLinesWithDifferentPassingTimes() throws {
        let (session, ids, _, arrival) = try fixture([Point2(-2, 0), Point2(0, -2)])
        let targets = [Point2(2, 0), Point2(0, 2)]
        try place(targets, ids: ids, at: arrival, in: session)
        XCTAssertEqual(try closePasses(session).count, 1)
        try session.perform(try session.show.makeSetPaths(into: arrival, [
            ids[0]: [.hold(counts: Rational(4)), .line(counts: Rational(4), to: targets[0])],
            ids[1]: [.line(counts: Rational(4), to: targets[1]), .hold(counts: Rational(4))],
        ]))
        XCTAssertTrue(try closePasses(session).isEmpty)
        let paths = session.show.transition(into: arrival)?.paths
        try session.perform(try session.show.makeForm(.line(start: targets[0], end: targets[1]), members: ids, at: arrival))
        XCTAssertEqual(session.show.forms.last?.members, ids)
        XCTAssertEqual(session.show.transition(into: arrival)?.paths, paths)
        XCTAssertTrue(try closePasses(session).isEmpty)
    }

    func testUnselectedArcIsCheckedInsteadOfItsStraightChord() throws {
        let (session, ids, _, arrival) = try fixture([Point2(0, 0), Point2(-3, 6), Point2(0, -2)])
        let targets = [Point2(4, 0), Point2(-4, 2)]
        try place(targets + [Point2(0, 2)], ids: ids, at: arrival, in: session)
        XCTAssertTrue(try closePasses(session).isEmpty, "Straight chords miss the curved collision")
        try session.perform(try session.show.makeSetPaths(into: arrival, [
            ids[2]: [.arc(counts: Rational(8), to: Point2(0, 2), sweep: -180)],
        ]))
        XCTAssertTrue(try closePasses(session).contains { $0.isSampled })
        let arc = session.show.transition(into: arrival)?.paths[ids[2]]
        try session.perform(try session.show.makeForm(.line(start: targets[0], end: targets[1]), members: Array(ids.prefix(2)), at: arrival))
        XCTAssertTrue(try closePasses(session).isEmpty)
        XCTAssertEqual(session.show.transition(into: arrival)?.paths[ids[2]], arc)
        XCTAssertEqual(session.show.forms.last?.members, Array(ids.prefix(2).reversed()))
    }

    func testLargeReversedFormationReducesClosePasses() throws {
        let points = (0..<350).map { Point2((Double($0) - 174.5) * 0.3, 0) }
        let (session, ids, _, arrival) = try fixture(points)
        try place(points.reversed(), ids: ids, at: arrival, in: session)
        let start = Date()
        try session.perform(try session.show.makeForm(.line(start: points[0], end: points[349]), members: ids, at: arrival))
        print("350-performer collision assignment: \(Date().timeIntervalSince(start)) seconds")
        XCTAssertEqual(session.show.forms.last?.members, ids)
        XCTAssertTrue(try closePasses(session).isEmpty)
    }

    func testExhaustedBudgetKeepsACompleteAssignment() throws {
        let (session, ids, _, arrival) = try fixture([Point2(-2, 0), Point2(2, 0)])
        let targets = [Point2(-2, 0), Point2(2, 0)], initial = Array(ids.reversed())
        for budget in 0...8 {
            let result = session.show.collisionAwareOrder(initial, to: targets, at: arrival, workLimit: budget)
            XCTAssertEqual(Set(result), Set(ids))
            XCTAssertEqual(result, session.show.collisionAwareOrder(initial, to: targets, at: arrival, workLimit: budget))
            if budget == 0 { XCTAssertEqual(result, initial) }
        }
    }

    func testDenseCurvedSearchStopsWithinItsWorkBudget() throws {
        let points = (0..<80).map { i in
            Point2(20 * cos(Double(i) * .pi / 40), 20 * sin(Double(i) * .pi / 40))
        }
        let (session, ids, _, arrival) = try fixture(points)
        let targets = Array(points.reversed())
        try place(targets, ids: ids, at: arrival, in: session)
        let paths = Dictionary(uniqueKeysWithValues: zip(ids, targets).map {
            ($0, Optional([PathSegment.arc(counts: Rational(8), to: $1, sweep: 90)]))
        })
        try session.perform(try session.show.makeSetPaths(into: arrival, paths))
        let start = Date()
        let result = session.show.collisionAwareOrder(ids, to: targets, at: arrival, workLimit: 5_000)
        print("80-performer dense curved budget: \(Date().timeIntervalSince(start)) seconds")
        XCTAssertEqual(result, ids, "An incompletely scored baseline must retain the original assignment")
    }

    func testDisabledClearanceUsesDistanceOnly() throws {
        let (session, ids, _, arrival) = try fixture([Point2(-2, 0), Point2(2, 0)])
        try place([Point2(2, 0), Point2(-2, 0)], ids: ids, at: arrival, in: session)
        var show = session.show
        show.analysis.minClearance = 0
        XCTAssertEqual(show.proximityOrder(ids, to: [Point2(-2, 0), Point2(2, 0)], at: arrival), ids.reversed())
    }
}
