import XCTest
import DrillTiming
import FieldworkTour
@testable import DrillCore

final class EvaluationAnalysisTests: XCTestCase {
    /// Two performers, preset → 16-count move.
    func makeMove(from a: [Point2], to b: [Point2], counts: Int = 16) throws -> DocumentSession {
        let session = try DocumentSession(show: try Show.makeNew(title: "Move", measures: 8))
        try session.perform(try session.show.makeRoster([RosterSectionRequest(name: "Trumpet", prefix: "T", count: a.count)]))
        let ids = session.show.performers.map(\.id)
        let preset = session.show.sets[0].id
        try session.perform(.setPlacements(preset, Dictionary(uniqueKeysWithValues: zip(ids, a.map { Placement.placed(Position($0)) }))))
        try session.perform(try session.show.makeCreateSet(after: preset, counts: counts))
        try session.perform(.setPlacements(session.show.sets[1].id, Dictionary(uniqueKeysWithValues: zip(ids, b.map { Placement.placed(Position($0)) }))))
        return session
    }

    func testStraightPathEvaluationAcrossSetBoundary() throws {
        let session = try makeMove(from: [Point2(0, 0)], to: [Point2(8, 4)])
        let evaluator = try SceneEvaluator(show: session.show, movementID: session.show.movements[0].id)
        let mid = evaluator.evaluate(pulse: 8)
        XCTAssertEqual(mid.performers[0].x, 4, accuracy: 1e-12)
        XCTAssertEqual(mid.performers[0].y, 2, accuracy: 1e-12)
        XCTAssertEqual(mid.nextSetIndex, 1)
        let arrival = evaluator.evaluate(pulse: 16)
        XCTAssertEqual(arrival.setIndex, 1)
        XCTAssertNil(arrival.nextSetIndex)
        XCTAssertEqual(arrival.performers[0].x, 8, accuracy: 1e-12)
        // Audio time drives the same evaluation: counts are quarter notes at 120 BPM.
        let viaTime = evaluator.evaluate(audioTime: 4.0)
        XCTAssertEqual(viaTime.performers[0].x, 4, accuracy: 1e-12)
        XCTAssertEqual(viaTime.pulse, 8, accuracy: 1e-12)
    }

    func testUnresolvedIsExplicitNotOrigin() throws {
        let session = try DocumentSession(show: try Show.makeNew(title: "U", measures: 4))
        try session.perform(try session.show.makeRoster([RosterSectionRequest(name: "Drum", prefix: "D", count: 1)]))
        let evaluator = try SceneEvaluator(show: session.show, movementID: session.show.movements[0].id)
        XCTAssertEqual(evaluator.evaluate(pulse: 0).performers[0].state, .unresolved)
        let issues = try DrillAnalyzer.analyze(session.show, movementID: session.show.movements[0].id)
        XCTAssertEqual(issues.map(\.kind), [.unresolvedPosition])
    }

    func testStrideWarningUsesDistancePerCount() throws {
        let step = Field.eightToFive
        // 16 counts covering 10 yards = 16-to-5: fine. 16 counts covering 20 yards = 4-to-5: warning.
        let session = try makeMove(from: [Point2(0, 0), Point2(0, 10)], to: [Point2(10 * Field.yard, 0), Point2(20 * Field.yard, 10)])
        let issues = try DrillAnalyzer.analyze(session.show, movementID: session.show.movements[0].id)
        let strides = issues.filter { $0.kind == .largeStride }
        XCTAssertEqual(strides.count, 1)
        XCTAssertEqual(strides[0].performers, [session.show.performers[1].id])
        XCTAssertEqual(strides[0].measured ?? 0, 20 * Field.yard / 16, accuracy: 1e-9)
        XCTAssertTrue(strides[0].message.contains("4.0 to 5"), strides[0].message)
        _ = step
    }

    func testClosePassDetectedOnlyWhenPathsConverge() throws {
        // Two performers swap places along the same line: they meet in the middle.
        let crossing = try makeMove(from: [Point2(-4, 0), Point2(4, 0)], to: [Point2(4, 0.2), Point2(-4, 0.2)])
        let passes = try DrillAnalyzer.analyze(crossing.show, movementID: crossing.show.movements[0].id).filter { $0.kind == .closePass }
        XCTAssertEqual(passes.count, 1)
        XCTAssertLessThan(passes[0].measured ?? 1, 0.25)
        // A tight block marching together is not flagged.
        let block = try makeMove(from: [Point2(0, 0), Point2(0.4, 0)], to: [Point2(0, 5), Point2(0.4, 5)])
        XCTAssertTrue(try DrillAnalyzer.analyze(block.show, movementID: block.show.movements[0].id).filter { $0.kind == .closePass }.isEmpty)
    }

    func testOutOfBounds() throws {
        let session = try makeMove(from: [Point2(0, 0)], to: [Point2(0, 40)])
        let issues = try DrillAnalyzer.analyze(session.show, movementID: session.show.movements[0].id)
        XCTAssertTrue(issues.contains { $0.kind == .outOfBounds })
    }

    func testSampleShowBuildsThroughCommands() throws {
        let show = try SampleShow.make()
        XCTAssertNoThrow(try show.validate())
        XCTAssertEqual(show.sets.count, 4)
        XCTAssertEqual(show.performers.count, 18)
        XCTAssertEqual(show.forms.count, 2)
        let issues = try DrillAnalyzer.analyze(show, movementID: show.movements[0].id)
        XCTAssertFalse(issues.contains { $0.kind == .unresolvedPosition })
    }

    func testTourAdvancesOnlyOnSuccessfulActions() {
        var tour = Tour()
        XCTAssertEqual(tour.currentStep?.id, "roster")
        tour.handle("setField")              // wrong step: ignored
        XCTAssertEqual(tour.currentStep?.id, "roster")
        tour.handle("addPerformers")
        XCTAssertEqual(tour.currentStep?.id, "field")
        tour.handle(TourEvent.fieldKept)
        tour.handle(TourEvent.countsOnly)    // audio step
        XCTAssertEqual(tour.currentStep?.id, "align")
        tour.back()
        XCTAssertEqual(tour.currentStep?.id, "audio")
        tour.skip()
        tour.skip()
        // The set step needs both a new set and a moved formation.
        tour.handle("createSet")
        XCTAssertEqual(tour.currentStep?.id, "form")
        tour.handle("applyForm")
        tour.handle("createSet")
        XCTAssertEqual(tour.currentStep?.id, "set")
        tour.handle("setPlacements")
        XCTAssertEqual(tour.currentStep?.id, "play")
        tour.dismiss()
        XCTAssertNil(tour.currentStep)
        tour.restart()
        XCTAssertEqual(tour.currentStep?.id, "roster")
        // Persisted progress from an older tour version is ignored.
        var old = TourProgress(version: 0)
        old.stepIndex = 5
        XCTAssertEqual(Tour(progress: old).currentStep?.id, "roster")
        for step in Tour.gettingStarted {
            XCTAssertLessThanOrEqual(step.body.split(separator: ".").count, 2, "coach marks stay short")
        }
    }

    func testLargeFixtureEvaluates() throws {
        let show = try SampleShow.makeLarge(performers: 350, sets: 150)
        let evaluator = try SceneEvaluator(show: show, movementID: show.movements[0].id)
        XCTAssertEqual(evaluator.evaluate(pulse: 100.5).performers.count, 350)
        XCTAssertEqual(evaluator.sets.count, 150)
    }
}
