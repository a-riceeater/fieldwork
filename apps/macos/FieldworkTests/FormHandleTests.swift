import XCTest
import AppKit
import DrillCore
@testable import Fieldwork

final class FormHandleTests: XCTestCase {
    @MainActor
    func testArcGripsStaySeparateAndDraggingDoesNotJump() throws {
        let session = try DocumentSession(show: SampleShow.make())
        let model = EditorModel(session: session, assets: [:])
        let set = model.currentSetID
        let members = Array(model.show.performers.prefix(9).map(\.id))
        let geometry = FormGeometry.arc(start: Point2(-10, 0), end: Point2(10, 0), bulge: 5)
        model.perform(try model.show.makeForm(geometry, members: members, at: set))
        model.selection = Set(members)
        model.snapEnabled = false
        let coordinator = FieldCanvas.Coordinator(model: model)
        let view = FieldCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.delegate = coordinator
        view.state = model.canvasState()
        let form = try XCTUnwrap(view.state?.forms.first)
        let grips = view.formHandlePositions(geometry)
        for (anchor, grip) in zip(geometry.handles, grips) {
            let point = view.transform.toView(anchor, in: view.bounds)
            XCTAssertEqual(grip.distance(to: point), 30, accuracy: 1e-6)
            for dot in try XCTUnwrap(view.state?.dots).filter({ members.contains($0.id) }) {
                XCTAssertGreaterThan(grip.distance(to: view.transform.toView(dot.point, in: view.bounds)), 20)
            }
        }
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        // Grabbing the displaced endpoint grip without moving leaves geometry intact.
        view.mouseDown(with: try mouse(.leftMouseDown, at: grips[0]))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: grips[0]))
        view.mouseUp(with: try mouse(.leftMouseUp, at: grips[0]))
        XCTAssertEqual(model.show.form(form.id)?.geometry, geometry)
        let end = CGPoint(x: grips[0].x + 24, y: grips[0].y + 16)
        view.mouseDown(with: try mouse(.leftMouseDown, at: grips[0]))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
        view.mouseUp(with: try mouse(.leftMouseUp, at: end))
        let delta = Point2(24 / Double(view.transform.scale), 16 / Double(view.transform.scale))
        let expected = geometry.movingHandle(0, to: geometry.handles[0] + delta)
        let reshaped = try XCTUnwrap(model.show.form(form.id)?.geometry)
        for (actual, target) in zip(reshaped.handles, expected.handles) {
            XCTAssertLessThan(actual.distance(to: target), 1e-9)
        }
        // Dragging a performer at an endpoint translates the whole arc instead.
        model.undo()
        view.state = model.canvasState()
        let dot = view.transform.toView(geometry.handles[0], in: view.bounds)
        let movedDot = CGPoint(x: dot.x + 24, y: dot.y + 16)
        view.mouseDown(with: try mouse(.leftMouseDown, at: dot))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: movedDot))
        view.mouseUp(with: try mouse(.leftMouseUp, at: movedDot))
        let translated = try XCTUnwrap(model.show.form(form.id)?.geometry)
        for (actual, target) in zip(translated.handles, geometry.translated(by: delta).handles) {
            XCTAssertLessThan(actual.distance(to: target), 1e-9)
        }
    }
}
