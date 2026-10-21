import XCTest
import DrillCore
@testable import Fieldwork

final class ArrangementTests: XCTestCase {
    @MainActor
    func testCircleDiameterAndSpacingStayLinkedAndUndoable() throws {
        let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
        let set = model.currentSetID
        let ids = model.show.performers.map(\.id)
        model.perform(try model.show.makeDrawnSet([.circle(center: Point2(3, 4), radius: 5)], members: ids, at: set))
        let original = model.show
        let form = try XCTUnwrap(model.show.forms(on: set).first)
        model.spaceCircle(form.id, spacingSteps: 3)
        let spaced = try XCTUnwrap(model.show.form(form.id))
        XCTAssertEqual(spaced.geometry.neighborSpacing(count: ids.count) / model.show.field.stepSize, 3, accuracy: 1e-9)
        XCTAssertEqual(spaced.members, form.members)
        model.resizeCircle(form.id, diameterSteps: 20)
        guard case .circle(let center, let radius) = model.show.form(form.id)?.geometry else { return XCTFail("Expected circle") }
        XCTAssertEqual(center, Point2(3, 4))
        XCTAssertEqual(radius / model.show.field.stepSize, 10, accuracy: 1e-9)
        let resized = model.show
        model.spaceCircle(form.id, spacingSteps: 0)
        model.resizeCircle(form.id, diameterSteps: -.infinity)
        XCTAssertEqual(model.show, resized)
        model.undo()
        model.undo()
        XCTAssertEqual(model.show, original)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 3)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(condition())
    }

    @MainActor
    func testBlockedCalculationLeavesEditorResponsiveAndCommitsOneUndoStep() throws {
        let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
        let original = model.show
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        model.buildArrangement { _ in
            XCTAssertFalse(Thread.isMainThread)
            guard gate.wait(timeout: .now() + 3) == .success else { throw DrillError("Test worker timed out") }
            return .renameShow("Arranged")
        }
        XCTAssertTrue(model.isArranging)
        XCTAssertFalse(model.isEditable)
        XCTAssertEqual(model.show, original)
        // This main-actor edit runs while calculation is deliberately blocked.
        model.statusMessage = "Still responsive"
        XCTAssertEqual(model.statusMessage, "Still responsive")
        gate.signal()
        waitUntil { !model.isArranging }
        XCTAssertEqual(model.show.title, "Arranged")
        XCTAssertEqual(model.session.revision, 1)
        model.undo()
        XCTAssertEqual(model.show, original)
        model.redo()
        XCTAssertEqual(model.show.title, "Arranged")
    }

    @MainActor
    func testCancelAndContextChangesDiscardPendingResults() throws {
        let invalidations: [(EditorModel) -> Void] = [
            { $0.cancelArrangement() },
            { $0.selection = [$0.show.performers[0].id] },
            { $0.currentSetID = $0.show.sets[1].id },
            { $0.perform(.renameShow("Newer edit")) },
        ]
        for invalidate in invalidations {
            let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
            let gate = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            model.buildArrangement { _ in
                started.signal()
                defer { finished.signal() }
                guard gate.wait(timeout: .now() + 3) == .success else { throw DrillError("Test worker timed out") }
                return .renameShow("Stale result")
            }
            XCTAssertTrue(model.isArranging)
            // Cancel a calculation already running; cancellation before its closure starts
            // correctly skips the closure and would never signal `finished`.
            XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
            invalidate(model)
            XCTAssertFalse(model.isArranging)
            let expected = model.show
            gate.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertEqual(model.show, expected)
            XCTAssertNotEqual(model.show.title, "Stale result")
        }
    }

    @MainActor
    func testWorkerFailureClearsProgressAndLeavesDocumentUntouched() throws {
        let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
        let before = model.show
        model.buildArrangement { _ in throw DrillError("Cannot arrange this selection") }
        waitUntil { !model.isArranging }
        XCTAssertEqual(model.show, before)
        XCTAssertEqual(model.statusMessage, "Cannot arrange this selection")
        XCTAssertTrue(model.isEditable)
    }
}
