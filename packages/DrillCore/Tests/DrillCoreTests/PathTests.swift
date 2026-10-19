import XCTest
import DrillTiming
@testable import DrillCore

final class PathTests: XCTestCase {
    /// Performers moving preset → set 2 over `counts` counts, with optional paths into set 2.
    func makeMove(from a: [Point2], to b: [Point2], counts: Int, paths: [Int: [PathSegment]] = [:]) throws -> DocumentSession {
        let session = try DocumentSession(show: try Show.makeNew(title: "Paths", measures: 8))
        try session.perform(try session.show.makeRoster([RosterSectionRequest(name: "Trumpet", prefix: "T", count: a.count)]))
        let ids = session.show.performers.map(\.id)
        let preset = session.show.sets[0].id
        try session.perform(.setPlacements(preset, Dictionary(uniqueKeysWithValues: zip(ids, a.map { Placement.placed(Position($0)) }))))
        try session.perform(try session.show.makeCreateSet(after: preset, counts: counts))
        let set2 = session.show.sets[1].id
        try session.perform(.setPlacements(set2, Dictionary(uniqueKeysWithValues: zip(ids, b.map { Placement.placed(Position($0)) }))))
        if !paths.isEmpty {
            try session.perform(try session.show.makeSetPaths(into: set2, Dictionary(uniqueKeysWithValues: paths.map { (ids[$0.key], Optional($0.value)) })))
        }
        return session
    }

    func evaluator(_ session: DocumentSession) throws -> SceneEvaluator {
        try SceneEvaluator(show: session.show, movementID: session.show.movements[0].id)
    }

    func assertPoint(_ p: EvaluatedPerformer, _ x: Double, _ y: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 1e-6, file: file, line: line)
    }

    func assertPoint(_ p: Point2, _ x: Double, _ y: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 1e-6, file: file, line: line)
    }

    func r(_ n: Int64, _ d: Int64 = 1) -> Rational { Rational(n, d) }

    // MARK: Evaluator vectors (FIELDWORK_PATHS §7)

    func testVector1HoldThenLine() throws {
        let session = try makeMove(from: [Point2(0, 0)], to: [Point2(4, 0)], counts: 8,
                                   paths: [0: [.hold(counts: r(4)), .line(counts: r(4), to: Point2(4, 0))]])
        let e = try evaluator(session)
        assertPoint(e.evaluate(pulse: 2).performers[0], 0, 0)
        XCTAssertFalse(e.evaluate(pulse: 2).performers[0].isMoving, "a hold is not moving")
        assertPoint(e.evaluate(pulse: 4).performers[0], 0, 0)
        XCTAssertTrue(e.evaluate(pulse: 4).performers[0].isMoving, "a boundary belongs to the later segment")
        assertPoint(e.evaluate(pulse: 6).performers[0], 2, 0)
        assertPoint(e.evaluate(pulse: 8).performers[0], 4, 0)
        // Stride is 1 m per count over counts 4–8, not the 0.5 m chord average.
        var analysis = session.show.analysis
        analysis.maxStride = 0.75
        try session.perform(.setAnalysisSettings(analysis))
        let strides = try DrillAnalyzer.analyze(session.show, movementID: session.show.movements[0].id).filter { $0.kind == .largeStride }
        XCTAssertEqual(strides.count, 1)
        XCTAssertEqual(strides[0].measured ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(strides[0].pulseRange, 4...8)
    }

    func testVector2And3QuarterArcs() throws {
        let session = try makeMove(from: [Point2(0, 10), Point2(10, 0)], to: [Point2(10, 0), Point2(0, 10)], counts: 4,
                                   paths: [0: [.arc(counts: r(4), to: Point2(10, 0), sweep: 90)],
                                           1: [.arc(counts: r(4), to: Point2(0, 10), sweep: -90)]])
        let e = try evaluator(session)
        let arc = try XCTUnwrap(ArcGeometry(from: Point2(0, 10), to: Point2(10, 0), sweepDegrees: 90))
        assertPoint(arc.center, 0, 0)
        assertPoint(e.evaluate(pulse: 1).performers[0], 3.826834, 9.238795)
        assertPoint(e.evaluate(pulse: 2).performers[0], 7.071068, 7.071068)
        let end = e.route(into: 1, performer: session.show.performers[0].id)!.point(at: 4).point
        XCTAssertEqual(end, Point2(10, 0), "the arc ends exactly on its end point")
        XCTAssertEqual(session.show.path(into: session.show.sets[1].id, performer: session.show.performers[0].id)!.length(from: Point2(0, 10)),
                       15.707963, accuracy: 1e-6)
        let back = try XCTUnwrap(ArcGeometry(from: Point2(10, 0), to: Point2(0, 10), sweepDegrees: -90))
        assertPoint(back.center, 0, 0)
        assertPoint(e.evaluate(pulse: 2).performers[1], 7.071068, 7.071068)
    }

    func testVector4ThreeQuarterArc() throws {
        let session = try makeMove(from: [Point2(10, 0)], to: [Point2(0, 10)], counts: 3,
                                   paths: [0: [.arc(counts: r(3), to: Point2(0, 10), sweep: 270)]])
        let e = try evaluator(session)
        assertPoint(e.evaluate(pulse: 1).performers[0], 0, -10)
        assertPoint(e.evaluate(pulse: 2).performers[0], -10, 0)
        assertPoint(e.evaluate(pulse: 3).performers[0], 0, 10)
        // The bulge is part of the path's bounds.
        let box = PerformerPath([.arc(counts: r(3), to: Point2(0, 10), sweep: 270)]).bounds(from: Point2(10, 0))
        XCTAssertEqual(box.minX, -10, accuracy: 1e-9)
        XCTAssertEqual(box.minY, -10, accuracy: 1e-9)
        XCTAssertEqual(box.maxX, 10, accuracy: 1e-9)
        XCTAssertEqual(box.maxY, 10, accuracy: 1e-9)
    }

    func testVector5MidCountCorner() throws {
        let session = try makeMove(from: [Point2(0, 0)], to: [Point2(4.5, 3.5)], counts: 8,
                                   paths: [0: [.line(counts: r(9, 2), to: Point2(4.5, 0)), .line(counts: r(7, 2), to: Point2(4.5, 3.5))]])
        let e = try evaluator(session)
        assertPoint(e.evaluate(pulse: 4).performers[0], 4, 0)
        assertPoint(e.evaluate(pulse: 5).performers[0], 4.5, 0.5)
        assertPoint(e.evaluate(pulse: 8).performers[0], 4.5, 3.5)
    }

    func testVector6SplitMoveCutsArc() throws {
        let session = try makeMove(from: [Point2(0, 10)], to: [Point2(10, 0)], counts: 4,
                                   paths: [0: [.arc(counts: r(4), to: Point2(10, 0), sweep: 90)]])
        let id = session.show.performers[0].id
        let set2 = session.show.sets[1].id
        let before = try evaluator(session)
        let subset = SetID()
        try session.perform(try session.show.makeSplitMove(into: set2, atCount: r(1), newSetID: subset))
        let left = try XCTUnwrap(session.show.path(into: subset, performer: id))
        let right = try XCTUnwrap(session.show.path(into: set2, performer: id))
        guard case .arc(let c1, let p1, let s1) = left.segments[0], case .arc(let c2, let p2, let s2) = right.segments[0] else {
            return XCTFail("both halves stay arcs")
        }
        XCTAssertEqual(c1, r(1))
        XCTAssertEqual(c2, r(3))
        assertPoint(p1, 3.826834, 9.238795)
        XCTAssertEqual(p2, Point2(10, 0))
        XCTAssertEqual(s1, 22.5, accuracy: 1e-9)
        XCTAssertEqual(s2, 67.5, accuracy: 1e-9)
        XCTAssertEqual(session.show.formation(subset)[id].position?.point, p1, "the subset stands exactly at the cut")
        let after = try evaluator(session)
        for pulse in stride(from: 0.0, through: 4, by: 0.125) {
            let a = before.evaluate(pulse: pulse).performers[0], b = after.evaluate(pulse: pulse).performers[0]
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
        }
        session.undo()
        XCTAssertEqual(session.show.path(into: set2, performer: id)?.segments.count, 1)
    }

    func testVector7StretchingTheMoveScalesSegments() throws {
        let session = try makeMove(from: [Point2(0, 0)], to: [Point2(4, 0)], counts: 8,
                                   paths: [0: [.hold(counts: r(4)), .line(counts: r(4), to: Point2(4, 0))]])
        let set2 = session.show.sets[1].id
        try session.perform(try session.show.makeSetMoveCounts(set2, counts: 16))
        XCTAssertEqual(session.show.path(into: set2, performer: session.show.performers[0].id)?.segments,
                       [.hold(counts: r(8)), .line(counts: r(8), to: Point2(4, 0))])
    }

    func testVector8DeletingACornerSetKeepsTheCorner() throws {
        let session = try makeMove(from: [Point2(0, 0)], to: [Point2(4, 0)], counts: 4)
        let s = session.show.sets[1].id
        try session.perform(try session.show.makeCreateSet(after: s, counts: 4))
        let b = session.show.sets[2].id
        let id = session.show.performers[0].id
        try session.perform(.setPlacements(b, [id: .placed(Position(x: 4, y: 3))]))
        let before = try evaluator(session)
        try session.perform(.deleteSet(s))
        XCTAssertEqual(session.show.path(into: b, performer: id)?.segments,
                       [.line(counts: r(4), to: Point2(4, 0)), .line(counts: r(4), to: Point2(4, 3))])
        let after = try evaluator(session)
        for pulse in stride(from: 0.0, through: 8, by: 0.5) {
            let p = before.evaluate(pulse: pulse).performers[0], q = after.evaluate(pulse: pulse).performers[0]
            XCTAssertEqual(p.x, q.x, accuracy: 1e-12)
            XCTAssertEqual(p.y, q.y, accuracy: 1e-12)
        }
        // A straight A → S → B in one direction at one pace merges back to no path.
        let straight = try makeMove(from: [Point2(0, 0)], to: [Point2(4, 0)], counts: 4)
        let s2 = straight.show.sets[1].id
        try straight.perform(try straight.show.makeCreateSet(after: s2, counts: 4))
        let b2 = straight.show.sets[2].id
        try straight.perform(.setPlacements(b2, [straight.show.performers[0].id: .placed(Position(x: 8, y: 0))]))
        try straight.perform(.deleteSet(s2))
        XCTAssertEqual(straight.show.pathCount, 0)
    }

    // MARK: Canonical form

    func testCanonicalForm() {
        let start = Point2(0, 0)
        // One straight line, or never moving, is no path.
        XCTAssertNil(PerformerPath.canonical([.line(counts: r(8), to: Point2(4, 0))], from: start, to: Point2(4, 0)))
        XCTAssertNil(PerformerPath.canonical([.hold(counts: r(8))], from: start, to: start))
        XCTAssertNil(PerformerPath.canonical([.line(counts: r(4), to: Point2(2, 0)), .line(counts: r(4), to: Point2(4, 0))], from: start, to: Point2(4, 0)),
                     "collinear legs at one pace merge into one line")
        // Zero-length lines become holds, and holds merge.
        XCTAssertEqual(PerformerPath.canonical([.hold(counts: r(1)), .line(counts: r(1), to: start), .line(counts: r(2), to: Point2(2, 0))], from: start, to: Point2(2, 0))?.segments,
                       [.hold(counts: r(2)), .line(counts: r(2), to: Point2(2, 0))])
        // A change of pace keeps both legs.
        XCTAssertEqual(PerformerPath.canonical([.line(counts: r(2), to: Point2(2, 0)), .line(counts: r(4), to: Point2(4, 0))], from: start, to: Point2(4, 0))?.segments.count, 2)
        // A flat arc becomes a line; arcs on one circle at one angular pace merge.
        XCTAssertNil(PerformerPath.canonical([.arc(counts: r(4), to: Point2(4, 0), sweep: 1e-9)], from: start, to: Point2(4, 0)))
        let halves = PerformerPath([.arc(counts: r(4), to: Point2(10, 0), sweep: 90)]).split(at: r(2), from: Point2(0, 10))
        XCTAssertEqual(PerformerPath.canonical(halves.left + halves.right, from: Point2(0, 10), to: Point2(10, 0))?.segments.count, 1)
    }

    // MARK: Commands keep paths valid

    func testMovingAnArrivalMovesTheLastLegAndArcsKeepTheirSweep() throws {
        let session = try makeMove(from: [Point2(0, 10)], to: [Point2(10, 0)], counts: 4,
                                   paths: [0: [.hold(counts: r(1)), .arc(counts: r(2), to: Point2(10, 0), sweep: 90), .hold(counts: r(1))]])
        let id = session.show.performers[0].id
        let set2 = session.show.sets[1].id
        try session.perform(try session.show.makeTranslate([id], at: set2, by: Point2(0, 2)))
        XCTAssertEqual(session.show.path(into: set2, performer: id)?.segments,
                       [.hold(counts: r(1)), .arc(counts: r(2), to: Point2(10, 2), sweep: 90), .hold(counts: r(1))])
        // Moving the start keeps the stored route; it starts from the new position.
        try session.perform(try session.show.makeTranslate([id], at: session.show.sets[0].id, by: Point2(1, 0)))
        XCTAssertEqual(session.show.path(into: set2, performer: id)?.segments.count, 3)
        XCTAssertNoThrow(try session.show.validate())
        // Moving the arrival onto the start leaves a zero-chord arc, which becomes a hold: no path at all.
        try session.perform(try session.show.makeSetCoordinate(id, at: set2, x: 1, y: 10))
        XCTAssertNil(session.show.path(into: set2, performer: id))
    }

    func testUnresolvedEndsAndRemovedPerformersDropPaths() throws {
        let session = try makeMove(from: [Point2(0, 0), Point2(0, 2)], to: [Point2(4, 0), Point2(4, 2)], counts: 8,
                                   paths: [0: [.hold(counts: r(4)), .line(counts: r(4), to: Point2(4, 0))],
                                           1: [.hold(counts: r(2)), .line(counts: r(6), to: Point2(4, 2))]])
        let ids = session.show.performers.map(\.id)
        let set2 = session.show.sets[1].id
        XCTAssertEqual(session.show.pathCount, 2)
        try session.perform(.setPlacements(set2, [ids[0]: .inactive]))
        XCTAssertNil(session.show.path(into: set2, performer: ids[0]))
        try session.perform(.removePerformers([ids[1]]))
        XCTAssertEqual(session.show.pathCount, 0)
        session.undo()
        session.undo()
        XCTAssertEqual(session.show.pathCount, 2)
    }

    func testCreateSetGivesTheNewMoveNoPathAndKeepsTheNextRoute() throws {
        let session = try makeMove(from: [Point2(0, 0)], to: [Point2(4, 0)], counts: 8,
                                   paths: [0: [.hold(counts: r(4)), .line(counts: r(4), to: Point2(4, 0))]])
        let id = session.show.performers[0].id
        let preset = session.show.sets[0].id, set2 = session.show.sets[1].id
        let newSet = SetID()
        try session.perform(try session.show.makeCreateSet(after: preset, counts: 4, newSetID: newSet))
        XCTAssertNil(session.show.path(into: newSet, performer: id))
        XCTAssertEqual(session.show.path(into: set2, performer: id)?.segments, [.hold(counts: r(4)), .line(counts: r(4), to: Point2(4, 0))])
    }

    func testSetPathsRequiresPlacedEndsAndExactCounts() throws {
        let session = try makeMove(from: [Point2(0, 0)], to: [Point2(4, 0)], counts: 8)
        let id = session.show.performers[0].id
        let set2 = session.show.sets[1].id
        let short = try session.show.makeSetPaths(into: set2, [id: [.hold(counts: r(3)), .line(counts: r(4), to: Point2(4, 0))]])
        XCTAssertThrowsError(try session.perform(short), "segments must fill the move exactly")
        let wrongEnd = try session.show.makeSetPaths(into: set2, [id: [.hold(counts: r(4)), .line(counts: r(4), to: Point2(5, 0))]])
        XCTAssertThrowsError(try session.perform(wrongEnd))
        XCTAssertEqual(session.show.pathCount, 0, "a rejected edit changes nothing")
        XCTAssertThrowsError(try session.show.makeSetPaths(into: session.show.sets[0].id, [id: []]), "the preset has no move")
    }

    func testHoldPhasesWaypointsCurvesPaceAndStraighten() throws {
        let session = try makeMove(from: [Point2(0, 0)], to: [Point2(8, 0)], counts: 8)
        let id = session.show.performers[0].id
        let set2 = session.show.sets[1].id
        try session.perform(try session.show.makeHoldPhases(into: set2, performers: [id], startHold: r(2), endHold: nil))
        XCTAssertEqual(session.show.path(into: set2, performer: id)?.segments, [.hold(counts: r(2)), .line(counts: r(6), to: Point2(8, 0))])
        try session.perform(try session.show.makeHoldPhases(into: set2, performers: [id], startHold: nil, endHold: r(2)))
        XCTAssertEqual(session.show.path(into: set2, performer: id)?.segments,
                       [.hold(counts: r(2)), .line(counts: r(4), to: Point2(8, 0)), .hold(counts: r(2))])
        XCTAssertThrowsError(try session.show.makeHoldPhases(into: set2, performers: [id], startHold: r(4), endHold: r(4)))

        // A waypoint at count 4 (halfway along the leg) pulled sideways.
        try session.perform(try session.show.makeInsertWaypoint(into: set2, performer: id, atCount: r(4), at: Point2(4, 3)))
        var segments = try XCTUnwrap(session.show.path(into: set2, performer: id)).segments
        XCTAssertEqual(segments, [.hold(counts: r(2)), .line(counts: r(2), to: Point2(4, 3)), .line(counts: r(2), to: Point2(8, 0)), .hold(counts: r(2))])
        XCTAssertEqual(Show.waypointSegments(segments), [1])
        try session.perform(try session.show.makeMoveWaypoint(into: set2, performer: id, segment: 1, to: Point2(2, 4)))
        segments = try XCTUnwrap(session.show.path(into: set2, performer: id)).segments
        XCTAssertEqual(segments[1], .line(counts: r(2), to: Point2(2, 4)))

        // Even pace shares the 4 moving counts by leg length: √20 and √52.
        try session.perform(try session.show.makeEvenPace(into: set2, performers: [id]))
        let info = try session.show.pathSegmentInfo(into: set2, performer: id)
        XCTAssertEqual(info.map(\.kind), ["hold", "line", "line", "hold"])
        XCTAssertEqual(info[1].counts + info[2].counts, r(4))
        XCTAssertEqual(info[1].pace, info[2].pace, accuracy: 1e-2)
        XCTAssertEqual(info[3].startCount, r(6))

        // Curve the second leg, then drag it back to straight within snap.
        try session.perform(try session.show.makeCurveLeg(into: set2, performer: id, segment: 2, sagitta: 1))
        guard case .arc(_, _, let sweep)? = session.show.path(into: set2, performer: id)?.segments[2] else { return XCTFail("leg should be an arc") }
        let chord = Point2(2, 4).distance(to: Point2(8, 0))
        XCTAssertEqual(PerformerPath.sagitta(chord: chord, sweepDegrees: sweep), 1, accuracy: 1e-9)
        try session.perform(try session.show.makeCurveLeg(into: set2, performer: id, segment: 2, sagitta: 0.05, snap: 0.1))
        guard case .line? = session.show.path(into: set2, performer: id)?.segments[2] else { return XCTFail("leg should snap straight") }

        try session.perform(try session.show.makeDeleteWaypoint(into: set2, performer: id, segment: 1))
        XCTAssertEqual(session.show.path(into: set2, performer: id)?.segments.count, 3, "hold, one line, hold")
        try session.perform(try session.show.makeStraighten(into: set2, performers: [id]))
        XCTAssertNil(session.show.path(into: set2, performer: id))
        XCTAssertThrowsError(try session.show.makeStraighten(into: set2, performers: [id]))
    }

    // MARK: Validation

    func testValidationRejectsBrokenPaths() throws {
        let session = try makeMove(from: [Point2(0, 0)], to: [Point2(4, 0)], counts: 8,
                                   paths: [0: [.hold(counts: r(4)), .line(counts: r(4), to: Point2(4, 0))]])
        let good = session.show
        let id = good.performers[0].id
        func broken(_ change: (inout Show) -> Void) -> Show {
            var show = good
            change(&show)
            return show
        }
        let t = good.transitions.firstIndex { !$0.paths.isEmpty }!
        // 1. Unknown performer.
        XCTAssertThrowsError(try broken { $0.transitions[t].paths[PerformerID()] = $0.transitions[t].paths[id] }.validate())
        // 2. Not placed at both ends.
        XCTAssertThrowsError(try broken { $0.formations[$0.sets[0].id]![id] = .unresolved }.validate())
        // 3. No segments.
        XCTAssertThrowsError(try broken { $0.transitions[t].paths[id] = PerformerPath([]) }.validate())
        // 4. Counts must be positive and fill the move exactly.
        XCTAssertThrowsError(try broken { $0.transitions[t].paths[id] = PerformerPath([.hold(counts: .zero), .line(counts: r(8), to: Point2(4, 0))]) }.validate())
        XCTAssertThrowsError(try broken { $0.transitions[t].paths[id] = PerformerPath([.hold(counts: r(4)), .line(counts: r(9, 2), to: Point2(4, 0))]) }.validate())
        // 5. Points must be finite.
        XCTAssertThrowsError(try broken { $0.transitions[t].paths[id] = PerformerPath([.hold(counts: r(4)), .line(counts: r(4), to: Point2(.nan, 0))]) }.validate())
        // 6. Arcs turn between 0 and 360 degrees and have a chord.
        XCTAssertThrowsError(try broken { $0.transitions[t].paths[id] = PerformerPath([.hold(counts: r(4)), .arc(counts: r(4), to: Point2(4, 0), sweep: 360)]) }.validate())
        XCTAssertThrowsError(try broken { $0.transitions[t].paths[id] = PerformerPath([.arc(counts: r(4), to: Point2(0, 0), sweep: 90), .line(counts: r(4), to: Point2(4, 0))]) }.validate())
        // 7. The path ends at the arrival.
        XCTAssertThrowsError(try broken { $0.transitions[t].paths[id] = PerformerPath([.hold(counts: r(4)), .line(counts: r(4), to: Point2(4.01, 0))]) }.validate())
        // The preset has no move, so it cannot carry paths either.
        XCTAssertNoThrow(try good.validate())
    }

    // MARK: Analysis

    func testClosePassOnArcsIsSampled() throws {
        // A swings around a quarter circle through the point B stands on.
        let session = try makeMove(from: [Point2(0, 10), Point2(7.071068, 7.2)], to: [Point2(10, 0), Point2(7.071068, 7.2)], counts: 4,
                                   paths: [0: [.arc(counts: r(4), to: Point2(10, 0), sweep: 90)]])
        // B is standing still, so only A moves; the pass is still checked against B.
        let issues = try DrillAnalyzer.analyze(session.show, movementID: session.show.movements[0].id).filter { $0.kind == .closePass }
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].isSampled)
        XCTAssertLessThan(issues[0].measured ?? 1, 0.2)
        XCTAssertTrue(issues[0].message.contains("(sampled)"), issues[0].message)
        // The same pair moving straight is far apart.
        try session.perform(try session.show.makeStraighten(into: session.show.sets[1].id, performers: [session.show.performers[0].id]))
        XCTAssertTrue(try DrillAnalyzer.analyze(session.show, movementID: session.show.movements[0].id).filter { $0.kind == .closePass }.isEmpty)
    }

    func testClosePassBetweenStraightPiecesOfPathsIsExact() throws {
        // A waits 4 counts, then crosses B's straight path at the moment B is there.
        let session = try makeMove(from: [Point2(-4, 0), Point2(0, -4)], to: [Point2(4, 0), Point2(0, 4)], counts: 8,
                                   paths: [0: [.hold(counts: r(2)), .line(counts: r(4), to: Point2(4, 0)), .hold(counts: r(2))]])
        let issues = try DrillAnalyzer.analyze(session.show, movementID: session.show.movements[0].id).filter { $0.kind == .closePass }
        XCTAssertEqual(issues.count, 1)
        XCTAssertFalse(issues[0].isSampled)
        XCTAssertEqual(issues[0].measured ?? 1, 0, accuracy: 1e-9)
    }

    func testArcBulgeOutsideTheFieldIsReported() throws {
        let show = try Show.makeNew(title: "B", measures: 8)
        let width = show.field.width
        let y = width / 2 - 1
        let session = try makeMove(from: [Point2(-5, y)], to: [Point2(5, y)], counts: 8,
                                   paths: [0: [.arc(counts: r(8), to: Point2(5, y), sweep: 120)]])
        let issues = try DrillAnalyzer.analyze(session.show, movementID: session.show.movements[0].id).filter { $0.kind == .outOfBounds }
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].message.contains("during the move"), issues[0].message)
    }

    // MARK: Journals

    func testTransitionsAndCommandsWithoutPathsStillDecode() throws {
        let set = SetID()
        let old = #"{"id":"\#(TransitionID().description)","toSetID":"\#(set.description)","model":"straight"}"#
        let transition = try JSONDecoder().decode(Transition.self, from: Data(old.utf8))
        XCTAssertEqual(transition.paths, [:])
        let command = DrillCommand.setPaths(TransitionID(), [PerformerID(): PerformerPath([.hold(counts: r(1)), .arc(counts: r(3, 2), to: Point2(1, 2), sweep: -45)]),
                                                            PerformerID(): nil])
        XCTAssertEqual(try JSONDecoder().decode(DrillCommand.self, from: try JSONEncoder().encode(command)), command)
    }
}
