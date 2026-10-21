import XCTest
@testable import DrillCore

final class CurveTests: XCTestCase {
    private let points = [Point2(-12, 0), Point2(-4, 6), Point2(4, -6), Point2(12, 0)]

    func testCurveInterpolatesKnotsAndDistributesByLength() throws {
        let curve = FormGeometry.curve(points: points)
        let samples = curve.polyline()
        for point in points {
            XCTAssertLessThan(samples.map { $0.distance(to: point) }.min()!, 1e-8)
        }
        let dots = curve.distribute(101)
        XCTAssertEqual(dots.first, points.first)
        XCTAssertLessThan(try XCTUnwrap(dots.last).distance(to: points.last!), 1e-8)
        // Dense spacing follows arc length rather than spending equal time on each span.
        let spacing = zip(dots, dots.dropFirst()).map { $0.distance(to: $1) }
        XCTAssertLessThan(spacing.max()! / spacing.min()!, 1.04)
        XCTAssertEqual(curve.distribute(1), [curve.point(at: 0.5)])
        XCTAssertGreaterThan(curve.length, 24)
    }

    func testCoincidentPointsStayFiniteAndInvalidCurvesAreRejected() throws {
        let curve = FormGeometry.curve(points: [.zero, .zero, Point2(1, 0), Point2(1, 0), Point2(8, 4)])
        XCTAssertTrue(curve.distribute(20).allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertThrowsError(try DrawnShape.curve(points: []).validate())
        XCTAssertThrowsError(try DrawnShape.curve(points: [.zero, .zero]).validate())
        XCTAssertThrowsError(try DrawnShape.curve(points: [.zero, Point2(.infinity, 0)]).validate())
        XCTAssertEqual(FormGeometry.curve(points: [.zero, Point2(8, 0)]).distribute(3), [.zero, Point2(4, 0), Point2(8, 0)])
    }

    func testRoutingRetainsCurveAndReshapingIsUndoable() throws {
        let session = try DocumentSession(show: SampleShow.make())
        let set = session.show.sets[0].id, members = session.show.performers.map(\.id)
        let original = session.show
        try session.perform(try session.show.makeDrawnSet([.curve(points: points)], members: members, at: set))
        let form = try XCTUnwrap(session.show.forms(on: set).first)
        XCTAssertEqual(form.geometry.handles, points)
        XCTAssertEqual(Set(form.members), Set(members))
        let moved = form.geometry.movingHandle(1, to: Point2(-3, 8))
        XCTAssertEqual(moved.handles[1], Point2(-3, 8))
        XCTAssertEqual(moved.endpoints.0, points[0])
        XCTAssertEqual(moved.endpoints.1, points.last)
        XCTAssertEqual(form.geometry.translated(by: Point2(2, 3)).handles, points.map { $0 + Point2(2, 3) })
        session.undo()
        XCTAssertEqual(session.show, original)
        session.redo()
        XCTAssertEqual(session.show.forms(on: set).first, form)
    }
}
