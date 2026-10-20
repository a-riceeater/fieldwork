import XCTest
import DrillTiming
@testable import DrillCore

final class ProximityAssignmentTests: XCTestCase {
    private func session() throws -> DocumentSession {
        let session = try DocumentSession(show: Show.makeNew(title: "Proximity", measures: 8))
        try session.perform(try session.show.makeRoster([
            RosterSectionRequest(name: "Trumpet", prefix: "T", count: 4),
            RosterSectionRequest(name: "Guard", prefix: "G", count: 4),
        ]))
        return session
    }

    func testEveryQuickShapeKeepsNearbyDotsAcrossSectionsAndUndoes() throws {
        for shape in QuickShape.allCases {
            let session = try session()
            let set = session.show.sets[0].id
            let ids = session.show.performers.map(\.id)
            try session.perform(try session.show.makeQuickShape(shape, members: ids, at: set))
            let targets = ids.map { session.show.formation(set)[$0].position!.point }
            // Reverse roster order across both sections. Each member is now
            // closest to exactly one destination, including the bottom right.
            let expected = Dictionary(uniqueKeysWithValues: zip(ids, targets.reversed()))
            try session.perform(.setPlacements(set, expected.mapValues { .placed(Position(x: $0.x, y: $0.y, z: 2, facing: 90)) }))
            let before = session.show
            try session.perform(try session.show.makeQuickShape(shape, members: ids.reversed(), at: set, center: .zero))
            for id in ids {
                let position = try XCTUnwrap(session.show.formation(set)[id].position)
                XCTAssertLessThan(position.point.distance(to: expected[id]!), 1e-8, "\(shape)")
                XCTAssertEqual(position.z, 2)
                XCTAssertEqual(position.facing, 90)
            }
            let after = session.show
            session.undo()
            XCTAssertEqual(session.show, before)
            session.redo()
            XCTAssertEqual(session.show, after)
        }
    }

    func testDrawnFormsUseProximityAndKeepAssignmentsDuringHandleEdits() throws {
        for geometry in [FormGeometry.line(start: Point2(-7, 0), end: Point2(7, 0)),
                         .arc(start: Point2(-7, 0), end: Point2(7, 0), bulge: 3)] {
            let session = try session()
            let set = session.show.sets[0].id
            let ids = session.show.performers.map(\.id)
            let points = geometry.distribute(ids.count)
            try session.perform(.setPlacements(set, Dictionary(uniqueKeysWithValues: zip(ids.reversed(), points).map {
                ($0, Placement.placed(Position(x: $1.x, y: $1.y)))
            })))
            try session.perform(try session.show.makeForm(geometry, members: ids, at: set))
            let form = try XCTUnwrap(session.show.forms.first)
            XCTAssertEqual(form.members, Array(ids.reversed()))
            try session.perform(.updateFormGeometry(form.id, geometry.translated(by: Point2(0, 2))))
            XCTAssertEqual(session.show.forms.first?.members, form.members)
            try session.perform(.updateFormMembers(form.id, form.members.reversed()))
            XCTAssertEqual(session.show.forms.first?.members, ids)
        }
    }

    func testMatchingMinimizesTotalDistanceInsteadOfGreedilyTakingDots() throws {
        let session = try session()
        let set = session.show.sets[0].id
        let ids = Array(session.show.performers.prefix(2).map(\.id))
        try session.perform(.setPlacements(set, [
            ids[0]: .placed(Position(x: 4, y: 0)),
            ids[1]: .placed(Position(x: 0, y: 0)),
        ]))
        let points = [Point2(0, 0), Point2(10, 0)]
        XCTAssertEqual(session.show.proximityOrder(ids, to: points, at: set), ids.reversed())
        XCTAssertEqual(session.show.proximityOrder(ids.reversed(), to: points, at: set), ids.reversed())
    }

    func testPlaceUnplacedMatchesPreviousDotsAcrossSectionBlocks() throws {
        let session = try session()
        let preset = session.show.sets[0].id
        let ids = session.show.performers.map(\.id)
        try session.perform(try session.show.makePlaceUnplaced(at: preset))
        let points = ids.map { session.show.formation(preset)[$0].position!.point }
        let expected = Dictionary(uniqueKeysWithValues: zip(ids, points.reversed()))
        try session.perform(.setPlacements(preset, expected.mapValues { .placed(Position(x: $0.x, y: $0.y)) }))
        try session.perform(try session.show.makeCreateSet(after: preset, counts: 8, copyPositions: false))
        let arrival = try XCTUnwrap(session.show.nextSet(after: preset)).id
        try session.perform(try session.show.makePlaceUnplaced(at: arrival))
        for id in ids {
            XCTAssertEqual(session.show.formation(arrival)[id].position?.point, expected[id])
        }
    }

    func testMissingPositionsAndEqualDistancesHaveStableAssignments() throws {
        let session = try session()
        let set = session.show.sets[0].id
        let ids = session.show.performers.map(\.id)
        let points = FormGeometry.line(start: Point2(-7, 0), end: Point2(7, 0)).distribute(ids.count)
        XCTAssertEqual(session.show.proximityOrder(ids.reversed(), to: points, at: set), ids)
        try session.perform(.setPlacements(set, Dictionary(uniqueKeysWithValues: ids.map {
            ($0, Placement.placed(Position(x: 0, y: 0)))
        })))
        let first = session.show.proximityOrder(ids, to: points, at: set)
        XCTAssertEqual(Set(first), Set(ids))
        XCTAssertEqual(session.show.proximityOrder(ids.reversed(), to: points, at: set), first)
    }

    func testUnresolvedArrivalUsesPreviousPositionsAndUnplacedFillRemainingDots() throws {
        let session = try session()
        let preset = session.show.sets[0].id
        let ids = Array(session.show.performers.prefix(3).map(\.id))
        try session.perform(.setPlacements(preset, [ids[0]: .placed(Position(x: 10, y: 0))]))
        try session.perform(try session.show.makeCreateSet(after: preset, counts: 8, copyPositions: false))
        let arrival = try XCTUnwrap(session.show.nextSet(after: preset)).id
        let points = [Point2(-10, 0), Point2(0, 0), Point2(10, 0)]
        XCTAssertEqual(session.show.proximityOrder(ids, to: points, at: arrival), [ids[1], ids[2], ids[0]])
        // An actual current position takes precedence over the previous set.
        try session.perform(try session.show.makeSetCoordinate(ids[0], at: arrival, x: -10, y: 0))
        XCTAssertEqual(session.show.proximityOrder(ids, to: points, at: arrival), ids)
    }
}
