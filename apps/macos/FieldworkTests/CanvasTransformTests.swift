import XCTest
import DrillCore
@testable import Fieldwork

/// App-level tests for pure view logic. (Portable behavior is covered by the
/// package test suites, which also run on Windows.)
final class CanvasTransformTests: XCTestCase {
    func testWorldViewRoundTripAndZoomAnchor() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        var transform = CanvasTransform(scale: 6, center: Point2(10, -5))
        let p = Point2(-12.5, 7.25)
        let back = transform.toWorld(transform.toView(p, in: bounds), in: bounds)
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)

        let anchor = CGPoint(x: 200, y: 450)
        let before = transform.toWorld(anchor, in: bounds)
        transform.zoom(by: 2, at: anchor, in: bounds)
        let after = transform.toWorld(anchor, in: bounds)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-9)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-9)
        XCTAssertEqual(transform.scale, 12)
    }

    func testFitFieldKeepsWholeFieldVisible() {
        let field = Field.make(.highSchoolFootball)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let transform = CanvasTransform.fit(field.bounds, in: bounds)
        let corner = transform.toView(Point2(field.bounds.maxX, field.bounds.maxY), in: bounds)
        XCTAssertLessThanOrEqual(corner.x, bounds.maxX)
        XCTAssertLessThanOrEqual(corner.y, bounds.maxY)
        // Back sideline (+y) is above the audience side in a non-flipped view.
        XCTAssertGreaterThan(transform.toView(Point2(0, 10), in: bounds).y, transform.toView(Point2(0, -10), in: bounds).y)
    }

    @MainActor
    func testNewShowRequestBuildsValidShowThroughCommands() throws {
        var request = NewShowRequest()
        request.sections = [.init(name: "Flute", prefix: "F", count: 6)]
        request.setCount = 3
        request.countsPerSet = 8
        let show = try request.build()
        XCTAssertEqual(show.performers.count, 6)
        XCTAssertEqual(show.sets.count, 3)
        XCTAssertNoThrow(try show.validate())
    }
}
