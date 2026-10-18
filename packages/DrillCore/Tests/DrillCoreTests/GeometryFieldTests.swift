import XCTest
import DrillTiming
@testable import DrillCore

final class GeometryFieldTests: XCTestCase {
    func testArcDistributesAtEqualArcLength() {
        let arc = FormGeometry.arc(start: Point2(-10, 0), end: Point2(10, 0), bulge: 6)
        let points = arc.distribute(9)
        XCTAssertEqual(points.first!.distance(to: Point2(-10, 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(points.last!.distance(to: Point2(10, 0)), 0, accuracy: 1e-9)
        // Apex sits at the sagitta on the left of start→end (+y here).
        XCTAssertEqual(points[4].x, 0, accuracy: 1e-9)
        XCTAssertEqual(points[4].y, 6, accuracy: 1e-9)
        let gaps = zip(points, points.dropFirst()).map { $0.distance(to: $1) }
        for gap in gaps { XCTAssertEqual(gap, gaps[0], accuracy: 1e-9, "equal chord ⇔ equal arc on a circle") }
        // Arc length of r = (100 + 36) / 12, half-angle asin(10 / r).
        let r = 136.0 / 12.0
        let expected = 2 * r * asin(10 / r) // minor arc: sagitta < half chord
        XCTAssertEqual(arc.length, expected, accuracy: 1e-9)
    }

    func testNegativeBulgeAndHandleEditing() {
        let arc = FormGeometry.arc(start: Point2(0, 0), end: Point2(10, 0), bulge: -2)
        XCTAssertEqual(arc.point(at: 0.5).y, -2, accuracy: 1e-9)
        let edited = arc.movingHandle(2, to: Point2(5, 3))
        guard case .arc(_, _, let bulge) = edited else { return XCTFail() }
        XCTAssertEqual(bulge, 3, accuracy: 1e-9)
        let line = FormGeometry.line(start: Point2(0, 0), end: Point2(8, 0))
        XCTAssertEqual(line.distribute(5).map(\.x), [0, 2, 4, 6, 8])
        XCTAssertEqual(line.distribute(1), [Point2(4, 0)])
    }

    func testFootballCoordinateDescriptions() {
        let field = Field.make(.highSchoolFootball)
        let d = CoordinateDescriber(field: field)
        let step = field.stepSize
        XCTAssertEqual(d.sideToSide(0), "On 50")
        XCTAssertEqual(d.sideToSide(-15 * Field.yard), "S1: On 35")
        XCTAssertEqual(d.sideToSide(-15 * Field.yard - 4 * step), "S1: 4.00 outside 35")
        XCTAssertEqual(d.sideToSide(15 * Field.yard - 2 * step), "S2: 2.00 inside 35")
        XCTAssertEqual(d.sideToSide(1 * step), "S2: 1.00 outside 50")
        let frontHash = field.checkpoints.first { $0.label == "front hash" }!.position
        XCTAssertEqual(d.frontToBack(frontHash), "On front hash")
        XCTAssertEqual(d.frontToBack(frontHash - 4 * step), "4.00 in front of front hash")
        XCTAssertEqual(d.frontToBack(frontHash + 2.5 * step), "2.50 behind front hash")
        // High school hashes are 53'4" from each sideline.
        XCTAssertEqual(frontHash - (-field.width / 2), 16.256, accuracy: 1e-9)
        XCTAssertEqual(field.length, 109.728, accuracy: 1e-9)
    }

    func testCustomFieldValidationAndSnap() throws {
        let field = Field.custom(length: 30, width: 20, stepSize: 0.75)
        XCTAssertNoThrow(try field.validate())
        XCTAssertThrowsError(try Field.custom(length: 1, width: 20, stepSize: 0.75).validate())
        let snapped = field.snap(Point2(1.0, -1.2), steps: 1)
        XCTAssertEqual(snapped, Point2(0.75, -1.5))
    }
}
