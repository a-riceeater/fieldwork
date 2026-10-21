import XCTest
import DrillTiming
@testable import DrillCore

final class DrawnShapeTests: XCTestCase {
    private func session(trumpets: Int = 8, guards: Int = 4) throws -> DocumentSession {
        let session = try DocumentSession(show: Show.makeNew(title: "Drawn", measures: 16))
        try session.perform(try session.show.makeRoster([
            RosterSectionRequest(name: "Trumpet", prefix: "T", count: trumpets),
            RosterSectionRequest(name: "Guard", prefix: "G", count: guards),
        ]))
        return session
    }

    func testRoutedCircleRetainsGeometryResizesAndUndoes() throws {
        let session = try session()
        let set = session.show.sets[0].id
        let ids = session.show.performers.map(\.id)
        let center = Point2(3, -2)
        let shape = DrawnShape.circle(center: center, radius: 7)
        let before = session.show
        try session.perform(try session.show.makeDrawnSet([shape], members: ids, at: set))
        let routed = session.show
        let form = try XCTUnwrap(routed.forms.first)
        XCTAssertEqual(form.geometry, .circle(center: center, radius: 7))
        XCTAssertEqual(Set(form.members), Set(ids))
        let spacing = 3 * routed.field.stepSize
        let radius = FormGeometry.circleRadius(spacing: spacing, count: ids.count)
        try session.perform(.updateFormGeometry(form.id, .circle(center: center, radius: radius)))
        let points = form.members.map { session.show.formation(set)[$0].position!.point }
        for i in points.indices {
            XCTAssertEqual(points[i].distance(to: points[(i + 1) % points.count]), spacing, accuracy: 1e-9)
        }
        XCTAssertEqual(session.show.forms[0].members, form.members)
        try session.undo()
        XCTAssertEqual(session.show, routed)
        try session.undo()
        XCTAssertEqual(session.show, before)
    }

    func testCircleHandlesAndRecoveryOfLegacyDots() throws {
        let session = try session()
        let set = session.show.sets[0].id
        let ids = session.show.performers.map(\.id)
        let geometry = FormGeometry.circle(center: Point2(3, 4), radius: 5)
        XCTAssertEqual(geometry.movingHandle(1, to: Point2(13, 4)), .circle(center: Point2(3, 4), radius: 10))
        XCTAssertEqual(geometry.movingHandle(0, to: .zero), .circle(center: .zero, radius: 5))
        XCTAssertEqual(geometry.translated(by: Point2(1, 2)), .circle(center: Point2(4, 6), radius: 5))
        XCTAssertEqual(Set(geometry.distribute(ids.count)).count, ids.count)
        let positions = Dictionary(uniqueKeysWithValues: zip(ids, geometry.distribute(ids.count)).map {
            ($0, Placement.placed(Position(x: $1.x, y: $1.y)))
        })
        try session.perform(.setPlacements(set, positions))
        let form = try XCTUnwrap(session.show.recoverCircle(members: ids, at: set))
        let before = session.show.formation(set)
        try session.perform(.applyForm(form))
        for id in ids {
            XCTAssertLessThan(session.show.formation(set)[id].position!.point.distance(to: before[id].position!.point), 1e-9)
        }
        try session.perform(.detachForm(form.id))
        try session.perform(try session.show.makeTranslate([ids[0]], at: set, by: Point2(1, 0)))
        XCTAssertNil(session.show.recoverCircle(members: ids, at: set))
        XCTAssertThrowsError(try session.perform(.applyForm(Form(setID: set, geometry: .circle(center: .zero, radius: 0), members: ids))))
    }

    private func distance(_ p: Point2, toStrokes strokes: [[Point2]]) -> Double {
        // A one-point stroke (the dot of "!") is a segment from the point to itself.
        strokes.flatMap { s in s.count == 1 ? [(s[0], s[0])] : zip(s, s.dropFirst()).map { ($0, $1) } }.map { a, b in
            let ab = b - a
            let t = ab.dot(ab) > 0 ? max(0, min(1, (p - a).dot(ab) / ab.dot(ab))) : 0
            return p.distance(to: a + ab * t)
        }.min()!
    }

    private func closestPair(_ points: [Point2]) -> Double {
        var best = Double.infinity
        for i in points.indices { for j in points.indices where j > i { best = min(best, points[i].distance(to: points[j])) } }
        return best
    }

    func testTextPointsLieOnTheStrokesWithoutStacking() throws {
        let text = TextShape("Hello 2026!", start: Point2(-30, 0), end: Point2(30, 0))
        let strokes = try text.strokes()
        let unit = text.height / 6
        let minimum = try text.minimumCount()
        for count in minimum...(minimum + 80) {
            let points = try text.points(count)
            XCTAssertEqual(points.count, count)
            for p in points { XCTAssertLessThan(distance(p, toStrokes: strokes), 1e-6) }
            XCTAssertGreaterThan(closestPair(points), unit * 0.2, "\(count) dots")
        }
        XCTAssertThrowsError(try text.points(minimum - 1))
    }

    func testEveryGlyphCanBeSpelled() throws {
        for character in StrokeFont.glyphs.keys {
            let text = TextShape(String(character), start: Point2(0, 0), end: Point2(8, 0))
            let minimum = try text.minimumCount()
            // A lone "." is one dot and has no stroke to put more on.
            if try text.strokes().allSatisfy({ $0.count == 1 }) {
                XCTAssertEqual(try text.points(minimum).count, minimum)
                XCTAssertThrowsError(try text.points(minimum + 1))
                continue
            }
            for count in [minimum, minimum + 7, minimum + 30] {
                let points = try text.points(count)
                XCTAssertEqual(points.count, count, "\(character)")
                XCTAssertGreaterThan(closestPair(points), 0.05, "\(character) with \(count)")
            }
        }
        XCTAssertThrowsError(try TextShape.validated("A~B"))
        XCTAssertThrowsError(try TextShape.validated("   "))
        XCTAssertEqual(try TextShape.validated("  go band "), "go band")
    }

    func testTextStandsOnItsBaselineAndFollowsItsDirection() throws {
        let text = TextShape("T", start: Point2(0, 0), end: Point2(4, 0))
        let points = try text.strokes().flatMap { $0 }
        XCTAssertEqual(Rect2(points: points).minY, 0, accuracy: 1e-9)
        XCTAssertEqual(Rect2(points: points).maxY, 6, accuracy: 1e-9)
        // Dragged right to left, the letters hang below the baseline, upside down.
        let flipped = try TextShape("T", start: Point2(4, 0), end: Point2(0, 0)).strokes().flatMap { $0 }
        XCTAssertEqual(Rect2(points: flipped).maxY, 0, accuracy: 1e-9)
        XCTAssertEqual(Rect2(points: flipped).minY, -6, accuracy: 1e-9)
    }

    func testShapesShareOneSpacingAndUseEveryPerformer() throws {
        let show = try session().show
        let long = DrawnShape.line(start: Point2(-20, 0), end: Point2(0, 0))
        let short = DrawnShape.line(start: Point2(5, 0), end: Point2(15, 0))
        let targets = try show.drawnTargets([long, short], count: 32)
        XCTAssertEqual(targets.map(\.count).reduce(0, +), 32)
        let gaps = targets.map { $0[0].distance(to: $0[1]) }
        XCTAssertEqual(gaps[0], gaps[1], accuracy: 0.1)

        let mixed: [DrawnShape] = [long, .arc(start: Point2(-10, 10), end: Point2(10, 10), bulge: 4),
                                   .block(Point2(-5, -20), Point2(5, -12)), .circle(center: Point2(30, 0), radius: 6),
                                   .text(TextShape("GO", start: Point2(-10, 20), end: Point2(10, 20)))]
        for count in [40, 77, 150] {
            let targets = try show.drawnTargets(mixed, count: count)
            let all = targets.flatMap { $0 }
            XCTAssertEqual(all.count, count)
            XCTAssertGreaterThan(closestPair(all), 0.1, "\(count)")
        }
        XCTAssertThrowsError(try show.drawnTargets(mixed, count: 5))
        XCTAssertThrowsError(try show.drawnTargets([], count: 5))
        XCTAssertThrowsError(try show.drawnTargets([.line(start: .zero, end: .zero)], count: 5))
    }

    func testBlockFillsItsRectangleFrontToBack() throws {
        let points = DrawnShape.gridPoints(12, in: Rect2(minX: 0, minY: 0, maxX: 6, maxY: 4))
        XCTAssertEqual(points.count, 12)
        XCTAssertEqual(Set(points.map(\.x)).count, 4)
        XCTAssertEqual(Set(points.map(\.y)).count, 3)
        XCTAssertEqual(points.first, Point2(0, 0))
        XCTAssertEqual(points.last, Point2(6, 4))
    }

    func testRoutingFillsShapesWithChosenSectionsAndHoldsEveryoneElse() throws {
        let session = try session()
        let preset = session.show.sets[0].id
        let trumpets = session.show.performers.filter { $0.label.hasPrefix("T") }.map(\.id)
        let guards = session.show.performers.filter { $0.label.hasPrefix("G") }.map(\.id)
        try session.perform(try session.show.makePlaceUnplaced(at: preset))
        try session.perform(try session.show.makeCreateSet(after: preset, counts: 16))
        let next = session.show.sets[1].id
        // A guard member wanders before the draw; routing without the guard puts them back.
        try session.perform(try session.show.makeTranslate([guards[0]], at: next, by: Point2(3, 3)))
        let shapes: [DrawnShape] = [.line(start: Point2(-10, 8), end: Point2(10, 8)),
                                    .text(TextShape("I", start: Point2(-1, -6), end: Point2(1, -6)))]
        let before = session.show
        try session.perform(try session.show.makeDrawnSet(shapes, members: trumpets, at: next, holdOthers: true))
        for id in guards {
            XCTAssertEqual(session.show.formation(next)[id], session.show.formation(preset)[id])
        }
        let forms = session.show.forms(on: next)
        XCTAssertEqual(forms.count, 1)
        let lineMembers = Set(forms[0].members)
        let text = try XCTUnwrap(shapes[1].points(trumpets.count - lineMembers.count))
        XCTAssertEqual(lineMembers.count + text.count, trumpets.count)
        for id in trumpets where !lineMembers.contains(id) {
            let p = try XCTUnwrap(session.show.formation(next)[id].position?.point)
            XCTAssertTrue(text.contains { $0.distance(to: p) < 1e-9 })
        }
        let after = session.show
        session.undo()
        XCTAssertEqual(session.show, before)
        session.redo()
        XCTAssertEqual(session.show, after)
        // Routing again replaces the earlier route.
        try session.perform(try session.show.makeDrawnSet([shapes[0]], members: trumpets, at: next, holdOthers: true))
        XCTAssertEqual(session.show.forms(on: next).map(\.members.count), [trumpets.count])
    }

    func testRoutingKeepsEveryoneCloseToWhereTheyWere() throws {
        let session = try session(trumpets: 12, guards: 0)
        let preset = session.show.sets[0].id
        let ids = session.show.performers.map(\.id)
        // Roster order runs right to left, so label order would cross everyone over.
        let start = FormGeometry.line(start: Point2(11, 0), end: Point2(-11, 0)).distribute(ids.count)
        try session.perform(.setPlacements(preset, Dictionary(uniqueKeysWithValues: zip(ids, start).map { ($0, .placed(Position($1))) })))
        try session.perform(try session.show.makeCreateSet(after: preset, counts: 16))
        let next = session.show.sets[1].id
        try session.perform(try session.show.makeDrawnSet([.block(Point2(-11, 10), Point2(11, 14))], members: ids, at: next, holdOthers: true))
        for (id, from) in zip(ids, start) {
            let to = try XCTUnwrap(session.show.formation(next)[id].position?.point)
            XCTAssertLessThan(abs(to.x - from.x), 4.5, "nobody crosses the field")
        }
    }

    func testQuickTextSpellsWithTheSelectionInOneStep() throws {
        let session = try session(trumpets: 30, guards: 0)
        let preset = session.show.sets[0].id
        let ids = session.show.performers.map(\.id)
        try session.perform(try session.show.makeQuickText("hi", members: ids, at: preset))
        XCTAssertEqual(session.show.performers.filter { session.show.formation(preset)[$0.id].position != nil }.count, ids.count)
        XCTAssertEqual(session.undoName, "Spell hi")
        XCTAssertThrowsError(try session.show.makeQuickText("hello world", members: Array(ids.prefix(3)), at: preset))
    }
}
