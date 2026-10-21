import XCTest
import AppKit
import DrillCore
@testable import Fieldwork

final class CurveToolTests: XCTestCase {
    @MainActor
    func testCurvePlacementPreviewReshapingAndCommitInBothModes() throws {
        for drawing in [false, true] {
            let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
            if drawing {
                model.drawNextSet()
                model.draft?.tool = .curve
            } else {
                model.selection = Set(model.show.performers.prefix(9).map(\.id))
                model.tool = .curve
            }
            model.snapEnabled = false
            let coordinator = FieldCanvas.Coordinator(model: model)
            let view = FieldCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.delegate = coordinator
            view.state = model.canvasState()
            let before = model.show
            func mouse(_ type: NSEvent.EventType, _ point: Point2) throws -> NSEvent {
                let v = view.transform.toView(point, in: view.bounds)
                return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(v, to: nil), modifierFlags: [],
                                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 1))
            }
            func click(_ point: Point2) throws {
                view.mouseDown(with: try mouse(.leftMouseDown, point))
                view.mouseUp(with: try mouse(.leftMouseUp, point))
            }
            func key(_ code: UInt16) throws {
                view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                               windowNumber: window.windowNumber, context: nil, characters: "",
                                                               charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
            }
            try click(Point2(-12, 0))
            try click(Point2(12, 0))
            try click(Point2(-4, 6))
            try click(Point2(4, -6))
            XCTAssertEqual(view.curvePoints.count, 4)
            XCTAssertEqual(try XCTUnwrap(view.curvePoints.first).x, -12, accuracy: 1e-8)
            XCTAssertEqual(try XCTUnwrap(view.curvePoints.last).x, 12, accuracy: 1e-8)
            XCTAssertEqual(model.show, before, "Preview must not change the document")
            // Delete undoes the most recently added shaping point, preserving the end.
            try key(51)
            XCTAssertEqual(view.curvePoints.count, 3)
            XCTAssertEqual(try XCTUnwrap(view.curvePoints.last).x, 12, accuracy: 1e-8)
            try click(Point2(4, -6))
            view.mouseDown(with: try mouse(.leftMouseDown, Point2(-4, 6)))
            view.mouseDragged(with: try mouse(.leftMouseDragged, Point2(-3, 8)))
            view.mouseUp(with: try mouse(.leftMouseUp, Point2(-3, 8)))
            XCTAssertEqual(view.curvePoints[1].x, -3, accuracy: 1e-8)
            XCTAssertEqual(view.curvePoints[1].y, 8, accuracy: 1e-8)
            // Render both the outline and performer preview before committing.
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let expected = FormGeometry.curve(points: view.curvePoints)
            try key(36)
            XCTAssertTrue(view.curvePoints.isEmpty)
            let deadline = Date(timeIntervalSinceNow: 3)
            while model.isArranging, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
            XCTAssertFalse(model.isArranging)
            if drawing {
                XCTAssertEqual(model.draft?.shapes.last?.formGeometry, expected)
                XCTAssertEqual(model.show, before)
                model.undo()
                XCTAssertTrue(model.draft?.shapes.isEmpty == true)
                model.redo()
                XCTAssertEqual(model.draft?.shapes.last?.formGeometry, expected)
            } else {
                XCTAssertTrue(model.show.forms(on: model.currentSetID).contains { $0.geometry == expected })
                model.undo()
                XCTAssertEqual(model.show, before)
            }
            // Escape discards the next curve; changing tools clears its points too.
            if !drawing { model.tool = .curve }
            view.state = model.canvasState()
            try click(Point2(-10, 0))
            try key(53)
            XCTAssertTrue(view.curvePoints.isEmpty)
            try click(Point2(-10, 0))
            if drawing { model.draft?.tool = .line } else { model.tool = .select }
            view.state = model.canvasState()
            XCTAssertTrue(view.curvePoints.isEmpty)
        }
    }
}
