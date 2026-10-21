import XCTest
import DrillCore
@testable import Fieldwork

final class DrawSetTests: XCTestCase {
    private let circle = DrawnShape.circle(center: Point2(3, 4), radius: 5)
    private let line = DrawnShape.line(start: Point2(-10, 0), end: Point2(10, 0))

    @MainActor
    private func model() throws -> EditorModel {
        let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
        model.drawNextSet()
        return model
    }

    @MainActor
    func testUndoAndRedoDrawShapesWithoutUndoingTheNewSet() throws {
        let model = try model()
        let set = model.currentSetID
        let show = model.show
        model.addDraftShape(circle)
        model.addDraftShape(line)
        XCTAssertEqual(model.undoName, "Draw Shape")
        model.undo()
        XCTAssertEqual(model.draft?.shapes, [circle])
        XCTAssertEqual(model.show, show)
        XCTAssertEqual(model.currentSetID, set)
        model.undo()
        XCTAssertEqual(model.draft?.shapes, [])
        XCTAssertFalse(model.canUndo)
        model.undo()
        XCTAssertEqual(model.show, show)
        XCTAssertNotNil(model.draft)
        model.redo()
        XCTAssertEqual(model.draft?.shapes, [circle])
        model.addDraftShape(circle)
        XCTAssertFalse(model.canRedo)
        model.clearDraftShapes()
        model.undo()
        XCTAssertEqual(model.draft?.shapes, [circle, circle])
        model.removeLastDraftShape()
        model.undo()
        XCTAssertEqual(model.draft?.shapes, [circle, circle])
    }

    @MainActor
    func testDoneWaitsForConfirmationAndCancelKeepsTheDrawing() throws {
        let model = try model()
        model.addDraftShape(circle)
        model.finishDraft()
        XCTAssertTrue(model.showsDraftExitConfirmation)
        XCTAssertEqual(model.draft?.shapes, [circle])
        model.cancelDraftExit()
        XCTAssertFalse(model.showsDraftExitConfirmation)
        XCTAssertEqual(model.draft?.shapes, [circle])
        model.finishDraft()
        model.confirmDraftExit()
        XCTAssertNil(model.draft)
        XCTAssertFalse(model.showsDraftExitConfirmation)
    }

    @MainActor
    func testLeavingActionsHaveNoSideEffectsUntilConfirmed() throws {
        let actions: [(EditorModel) -> Void] = [
            { $0.selectSet($0.show.sets[0].id) },
            { $0.addSet(counts: 8) },
            { $0.deleteCurrentSet() },
            { $0.drawNextSet() },
            { $0.seek(to: 0) },
            { $0.play() },
        ]
        for action in actions {
            let model = try model()
            model.addDraftShape(circle)
            let show = model.show, set = model.currentSetID, time = model.playheadSeconds
            action(model)
            XCTAssertTrue(model.showsDraftExitConfirmation)
            XCTAssertEqual(model.show, show)
            XCTAssertEqual(model.currentSetID, set)
            XCTAssertEqual(model.playheadSeconds, time)
            XCTAssertFalse(model.isPlaying)
            model.cancelDraftExit()
            XCTAssertEqual(model.draft?.shapes, [circle])
        }
        let model = try model()
        model.addDraftShape(circle)
        let destination = model.show.sets[0].id
        model.selectSet(destination)
        model.confirmDraftExit()
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.currentSetID, destination)
    }

    @MainActor
    func testOnlyChangesSinceAutoRouteRequireConfirmation() throws {
        let model = try model()
        model.addDraftShape(circle)
        model.autoRouteDraft()
        let deadline = Date(timeIntervalSinceNow: 3)
        while model.isArranging, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(model.draft?.routed, true)
        XCTAssertEqual(model.draft?.hasPendingChanges, false)
        model.addDraftShape(line)
        XCTAssertEqual(model.draft?.hasPendingChanges, true)
        model.undo()
        XCTAssertEqual(model.draft?.hasPendingChanges, false)
        model.finishDraft()
        XCTAssertNil(model.draft)
        XCTAssertFalse(model.showsDraftExitConfirmation)
        // Document undo resumes once drawing has ended.
        model.undo()
        XCTAssertEqual(model.session.undoName, "Add Set")
    }
}
