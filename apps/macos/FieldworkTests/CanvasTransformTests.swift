import XCTest
import DrillCore
import DrillTiming
@testable import Fieldwork

/// App-level tests for pure view logic. (Portable behavior is covered by the
/// package test suites, which also run on Windows.)
final class CanvasTransformTests: XCTestCase {
    @MainActor
    func testWholeCountsSettingControlsPauseSnappingAndPersists() throws {
        let suite = "FieldworkTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = try DocumentSession(show: try Show.makeNew(title: "Counts", measures: 4))
        let model = EditorModel(session: session, assets: [:], preferences: preferences)
        XCTAssertFalse(model.wholeCountsOnly)

        model.seek(to: 0.31)
        model.pause()
        XCTAssertEqual(model.playheadSeconds, 0.31, accuracy: 1e-9)

        model.wholeCountsOnly = true
        for (time, snapped) in [(0.19, 0.0), (0.25, 0.5), (0.31, 0.5), (1.81, 2.0)] {
            model.seek(to: time)
            model.pause()
            XCTAssertEqual(model.playheadSeconds, snapped, accuracy: 1e-9)
            XCTAssertEqual(model.transport.currentTime, snapped, accuracy: 1e-9)
        }
        let reopened = EditorModel(session: session, assets: [:], preferences: preferences)
        XCTAssertTrue(reopened.wholeCountsOnly)
        model.wholeCountsOnly = false
        model.seek(to: 0.31)
        model.pause()
        XCTAssertEqual(model.playheadSeconds, 0.31, accuracy: 1e-9)
    }

    @MainActor
    func testWholeCountPauseUsesTempoMapAndPreservesHoldOffsets() throws {
        var show = try Show.makeNew(title: "Hold", bpm: 60, measures: 4)
        try show.movements[0].timing.insertHold(after: show.movements[0].timing.events[3].id, seconds: 2)
        let suite = "FieldworkTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = EditorModel(session: try DocumentSession(show: show), assets: [:], preferences: preferences)
        model.wholeCountsOnly = true
        model.seek(to: 0.7)
        model.pause()
        XCTAssertEqual(model.playheadSeconds, 1, accuracy: 1e-9)
        model.seek(to: 5)
        model.pause()
        XCTAssertEqual(model.playheadSeconds, 5, accuracy: 1e-9)
    }

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
